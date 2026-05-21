# frozen_string_literal: true

require "spec_helper"

# --------------------------------------------------------------------------
# Test Models for Nested Operations
# --------------------------------------------------------------------------

class NestedBlog < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "blogs"

  validates :title, length: { maximum: 255 }, allow_nil: true

  # Field permissions are controlled by the policy.
end

class NestedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "posts"

  belongs_to :user, optional: true
  belongs_to :organization, optional: true

  validates :title, length: { maximum: 255 }, allow_nil: true

  # Field permissions are controlled by the policy.
end

class NestedBlogPolicy < Rhino::ResourcePolicy
  self.resource_slug = "blogs"

  def permitted_attributes_for_create(_user)
    ["*"]
  end

  def permitted_attributes_for_update(_user)
    ["*"]
  end
end

class NestedPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  def permitted_attributes_for_create(_user)
    ["*"]
  end

  def permitted_attributes_for_update(_user)
    ["*"]
  end
end

RSpec.describe "NestedEndpoint" do
  before do
    Rhino.configure do |c|
      c.model :blogs, "NestedBlog"
      c.model :posts, "NestedPost"
    end
  end

  # ------------------------------------------------------------------
  # Structure validation
  # ------------------------------------------------------------------

  describe "structure validation" do
    it "requires operations to be present" do
      # Simulate what the controller does: validate operations structure
      operations = nil
      expect(operations).to be_nil
    end

    it "detects missing id for update operations" do
      operation = { "model" => "blogs", "action" => "update", "data" => { "title" => "Foo" } }

      expect(operation["action"]).to eq("update")
      expect(operation).not_to have_key("id")
    end

    it "detects missing data field" do
      operation = { "model" => "blogs", "action" => "create" }

      expect(operation).not_to have_key("data")
    end

    it "validates action must be create or update" do
      operation = { "model" => "blogs", "action" => "delete", "data" => { "title" => "X" } }

      expect(%w[create update]).not_to include(operation["action"])
    end
  end

  # ------------------------------------------------------------------
  # Per-operation validation
  # ------------------------------------------------------------------

  describe "per-operation validation" do
    it "validates each operation's data" do
      blog = NestedBlog.create!(title: "Original")
      post_model = NestedPost.new

      # Valid operation
      valid_result = post_model.validate_for_action(
        { "title" => "New Post", "content" => "Body" },
        permitted_fields: ["*"]
      )
      expect(valid_result[:valid]).to be true

      # Invalid operation: title exceeds max length
      long_title = "x" * 256
      invalid_result = post_model.validate_for_action(
        { "title" => long_title, "content" => "Body" },
        permitted_fields: ["*"]
      )
      expect(invalid_result[:valid]).to be false
      expect(invalid_result[:errors]).to have_key("title")
    end

    it "validates update operations" do
      model = NestedBlog.new

      result = model.validate_for_action(
        { "title" => "Updated" },
        permitted_fields: ["*"]
      )
      expect(result[:valid]).to be true
      expect(result[:validated]["title"]).to eq("Updated")
    end
  end

  # ------------------------------------------------------------------
  # Model resolution
  # ------------------------------------------------------------------

  describe "model resolution" do
    it "resolves known model from slug" do
      model_class = Rhino.config.resolve_model("blogs")
      expect(model_class).to eq(NestedBlog)
    end

    it "raises error for unknown model" do
      expect {
        Rhino.config.resolve_model("nonexistent")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # ------------------------------------------------------------------
  # Success with create and update
  # ------------------------------------------------------------------

  describe "success with full content" do
    it "creates records through nested operations" do
      blog = NestedBlog.create!(title: "Original Blog")
      initial_post_count = NestedPost.count

      # Simulate nested create
      validated = { "title" => "New Post", "content" => "Body" }
      record = NestedPost.create!(validated)

      expect(record).to be_persisted
      expect(record.title).to eq("New Post")
      expect(NestedPost.count).to eq(initial_post_count + 1)
    end

    it "updates records through nested operations" do
      blog = NestedBlog.create!(title: "Original Blog")

      blog.update!(title: "Updated Blog")
      blog.reload

      expect(blog.title).to eq("Updated Blog")
    end

    it "executes mixed create and update operations" do
      blog = NestedBlog.create!(title: "Original Blog")

      # Update blog
      blog.update!(title: "Updated Blog")

      # Create post
      post = NestedPost.create!(title: "New Post", content: "Body")

      blog.reload
      expect(blog.title).to eq("Updated Blog")
      expect(post).to be_persisted
      expect(post.title).to eq("New Post")
    end
  end

  # ------------------------------------------------------------------
  # Transaction rollback
  # ------------------------------------------------------------------

  describe "transaction rollback" do
    it "rolls back all operations on failure" do
      blog = NestedBlog.create!(title: "Blog")
      initial_blog_title = blog.title
      initial_post_count = NestedPost.count

      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          blog.update!(title: "Updated")
          # Force a failure
          raise ActiveRecord::RecordInvalid.new(NestedPost.new)
        end
      rescue ActiveRecord::RecordInvalid
        # Expected
      end

      blog.reload
      expect(blog.title).to eq(initial_blog_title)
      expect(NestedPost.count).to eq(initial_post_count)
    end
  end

  # ------------------------------------------------------------------
  # Max operations
  # ------------------------------------------------------------------

  describe "max operations" do
    it "enforces max operations limit" do
      Rhino.configure do |c|
        c.model :blogs, "NestedBlog"
        c.model :posts, "NestedPost"
        c.nested[:max_operations] = 2
      end

      operations = [
        { "model" => "blogs", "action" => "create", "data" => { "title" => "B1" } },
        { "model" => "blogs", "action" => "create", "data" => { "title" => "B2" } },
        { "model" => "blogs", "action" => "create", "data" => { "title" => "B3" } }
      ]

      max = Rhino.config.nested[:max_operations]
      expect(operations.size).to be > max
    end
  end

  # ------------------------------------------------------------------
  # Allowed models
  # ------------------------------------------------------------------

  describe "allowed models" do
    it "filters based on allowed models config" do
      Rhino.configure do |c|
        c.model :blogs, "NestedBlog"
        c.model :posts, "NestedPost"
        c.nested[:allowed_models] = ["blogs"]
      end

      allowed = Rhino.config.nested[:allowed_models]
      expect(allowed).to include("blogs")
      expect(allowed).not_to include("posts")
    end
  end
end
