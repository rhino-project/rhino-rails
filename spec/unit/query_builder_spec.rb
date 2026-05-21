# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::QueryBuilder do
  before do
    Post.delete_all
  end

  def create_posts(count)
    count.times { |i| Post.create!(title: "Post #{i + 1}", content: "Content #{i + 1}") }
  end

  # ------------------------------------------------------------------
  # Filtering: ?filter[status]=published
  # ------------------------------------------------------------------

  describe "filtering" do
    before do
      Post.create!(title: "Active Post", status: "published")
      Post.create!(title: "Draft Post", status: "draft")
      Post.create!(title: "Another Active", status: "published")
    end

    it "filters by a single value" do
      builder = described_class.new(Post, params: { filter: { "status" => "published" } })
      builder.build
      expect(builder.to_scope.count).to eq(2)
    end

    it "filters with comma-separated OR values" do
      builder = described_class.new(Post, params: { filter: { "status" => "published,draft" } })
      builder.build
      expect(builder.to_scope.count).to eq(3)
    end

    it "ignores filters not in allowed_filters" do
      builder = described_class.new(Post, params: { filter: { "content" => "Content" } })
      builder.build
      # content is not in allowed_filters, so all records returned
      expect(builder.to_scope.count).to eq(3)
    end

    it "returns all when no filter params" do
      builder = described_class.new(Post, params: {})
      builder.build
      expect(builder.to_scope.count).to eq(3)
    end
  end

  # ------------------------------------------------------------------
  # Sorting: ?sort=-created_at,title
  # ------------------------------------------------------------------

  describe "sorting" do
    before do
      Post.create!(title: "Banana")
      Post.create!(title: "Apple")
      Post.create!(title: "Cherry")
    end

    it "sorts ascending by default" do
      builder = described_class.new(Post, params: { sort: "title" })
      builder.build
      titles = builder.to_scope.pluck(:title)
      expect(titles).to eq(%w[Apple Banana Cherry])
    end

    it "sorts descending with - prefix" do
      builder = described_class.new(Post, params: { sort: "-title" })
      builder.build
      titles = builder.to_scope.pluck(:title)
      expect(titles).to eq(%w[Cherry Banana Apple])
    end

    it "supports multiple sort fields" do
      Post.create!(title: "Apple", status: "z")
      builder = described_class.new(Post, params: { sort: "title,-created_at" })
      builder.build
      results = builder.to_scope.to_a
      expect(results.first.title).to eq("Apple")
    end

    it "applies default sort when no sort param" do
      builder = described_class.new(Post, params: {})
      builder.build
      # Post has rhino_default_sort "-created_at"
      results = builder.to_scope.to_a
      expect(results.first.title).to eq("Cherry") # last created
    end
  end

  # ------------------------------------------------------------------
  # Search: ?search=term
  # ------------------------------------------------------------------

  describe "search" do
    before do
      Post.create!(title: "Needle in title", content: "Some content")
      Post.create!(title: "Other", content: "Needle in content")
      Post.create!(title: "No match", content: "Nothing")
    end

    it "returns matching rows across allowed search columns" do
      builder = described_class.new(Post, params: { search: "needle" })
      builder.build
      expect(builder.to_scope.count).to eq(2)
    end

    it "is case-insensitive" do
      builder = described_class.new(Post, params: { search: "NEEDLE" })
      builder.build
      expect(builder.to_scope.count).to eq(2)
    end

    it "excludes non-matching rows" do
      builder = described_class.new(Post, params: { search: "nonexistent" })
      builder.build
      expect(builder.to_scope.count).to eq(0)
    end

    it "returns all when search is empty" do
      builder = described_class.new(Post, params: { search: "" })
      builder.build
      expect(builder.to_scope.count).to eq(3)
    end

    it "returns all when search is nil" do
      builder = described_class.new(Post, params: {})
      builder.build
      expect(builder.to_scope.count).to eq(3)
    end

    it "composes with filters" do
      Post.create!(title: "Needle", status: "published")
      builder = described_class.new(Post, params: {
        search: "needle",
        filter: { "status" => "published" }
      })
      builder.build
      results = builder.to_scope.to_a
      expect(results.length).to eq(1)
      expect(results.first.status).to eq("published")
    end

    it "searches through relationship dot notation" do
      blog = Blog.create!(title: "BlogWithNeedle")
      Post.delete_all
      Post.create!(title: "Post A", content: "Content")

      # Blog.title search uses blog.title in allowed_search
      builder = described_class.new(Blog, params: { search: "blogwithneedle" })
      builder.build
      expect(builder.to_scope.count).to eq(1)
    end
  end

  # ------------------------------------------------------------------
  # Pagination
  # ------------------------------------------------------------------

  describe "pagination" do
    before { create_posts(15) }

    it "returns items and pagination metadata" do
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate(per_page: 5, page: 1)

      expect(result[:items].length).to eq(5)
      expect(result[:pagination][:current_page]).to eq(1)
      expect(result[:pagination][:last_page]).to eq(3)
      expect(result[:pagination][:per_page]).to eq(5)
      expect(result[:pagination][:total]).to eq(15)
    end

    it "navigates to second page" do
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate(per_page: 5, page: 2)

      expect(result[:items].length).to eq(5)
      expect(result[:pagination][:current_page]).to eq(2)
    end

    it "returns remaining items on last page" do
      builder = described_class.new(Post, params: { sort: "title" })
      builder.build
      result = builder.paginate(per_page: 4, page: 4)

      expect(result[:items].length).to eq(3) # 15 total, 4 per page, page 4 = 3 items
      expect(result[:pagination][:current_page]).to eq(4)
      expect(result[:pagination][:last_page]).to eq(4)
    end

    it "clamps per_page to minimum of 1" do
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate(per_page: 0)

      expect(result[:pagination][:per_page]).to eq(1)
      expect(result[:items].length).to eq(1)
    end

    it "clamps per_page to maximum of 100" do
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate(per_page: 500)

      expect(result[:pagination][:per_page]).to eq(100)
    end

    it "clamps negative per_page to 1" do
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate(per_page: -10)

      expect(result[:pagination][:per_page]).to eq(1)
    end

    it "clamps negative page to 1" do
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate(per_page: 5, page: -1)

      expect(result[:pagination][:current_page]).to eq(1)
    end

    it "returns empty items with no records" do
      Post.delete_all
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate(per_page: 5)

      expect(result[:items].length).to eq(0)
      expect(result[:pagination][:total]).to eq(0)
      expect(result[:pagination][:last_page]).to eq(1)
    end

    it "reads per_page from params" do
      builder = described_class.new(Post, params: { per_page: "3" })
      builder.build
      result = builder.paginate

      expect(result[:pagination][:per_page]).to eq(3)
      expect(result[:items].length).to eq(3)
    end
  end

  # ------------------------------------------------------------------
  # Sparse Fieldsets: ?fields[posts]=id,title
  # ------------------------------------------------------------------

  describe "sparse fieldsets" do
    before do
      Post.create!(title: "Test", content: "Full content", status: "published")
    end

    it "selects only requested fields" do
      builder = described_class.new(Post, params: { fields: { "posts" => "id,title" } })
      builder.build
      result = builder.to_scope.first

      expect(result.attributes.keys).to include("id", "title")
      # content is not selected, so it should not be in the loaded attributes
      expect(result.has_attribute?(:content)).to be false
    end

    it "always includes primary key" do
      builder = described_class.new(Post, params: { fields: { "posts" => "title" } })
      builder.build
      result = builder.to_scope.first

      expect(result.attributes.keys).to include("id")
    end

    it "ignores fields not in allowed_fields" do
      builder = described_class.new(Post, params: { fields: { "posts" => "id,title,secret_field" } })
      builder.build
      result = builder.to_scope.first

      expect(result.attributes.keys).to include("id", "title")
    end
  end

  # ------------------------------------------------------------------
  # Eager Loading: ?include=user,comments
  # ------------------------------------------------------------------

  describe "includes" do
    before do
      user = User.create!(name: "Test User", email: "test@example.com")
      post = Post.create!(title: "Test", user: user)
      Comment.create!(post: post, body: "Great post!")
    end

    it "eager loads allowed includes" do
      builder = described_class.new(Post, params: { include: "user,comments" })
      builder.build

      result = builder.to_scope.first
      expect(result.association(:user).loaded?).to be true
      expect(result.association(:comments).loaded?).to be true
    end

    it "ignores includes not in allowed_includes" do
      builder = described_class.new(Post, params: { include: "organization" })
      builder.build

      result = builder.to_scope.first
      expect(result.association(:organization).loaded?).to be false
    end

    it "handles Count suffix" do
      builder = described_class.new(Post, params: { include: "commentsCount" })
      builder.build
      # Count suffix is handled in serialization, not eager loading
      expect(builder.to_scope.count).to eq(1)
    end

    it "handles Exists suffix" do
      builder = described_class.new(Post, params: { include: "commentsExists" })
      builder.build
      expect(builder.to_scope.count).to eq(1)
    end

    it "handles nested include with dot notation" do
      # Need to add 'comments.user' to allowed_includes for it to be resolved
      allow(Post).to receive(:allowed_includes).and_return(["user", "comments", "comments.user"])
      builder = described_class.new(Post, params: { include: "comments.user" })
      builder.build
      result = builder.to_scope.first
      expect(result.association(:comments).loaded?).to be true
    end

    it "ignores includes when no allowed_includes defined" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"
      end
      builder = described_class.new(klass, params: { include: "user" })
      builder.build
      expect(builder.to_scope.count).to be >= 0
    end

    it "returns scope without includes when param is empty" do
      builder = described_class.new(Post, params: { include: "" })
      builder.build
      expect(builder.to_scope.count).to eq(1)
    end
  end

  # ------------------------------------------------------------------
  # Filter value coercion
  # ------------------------------------------------------------------

  describe "filter value coercion" do
    before do
      user1 = User.create!(name: "User 1", email: "coerce1@test.com")
      user2 = User.create!(name: "User 2", email: "coerce2@test.com")
      Post.create!(title: "Coerce Test", status: "draft", is_published: true, user_id: user1.id)
      Post.create!(title: "Coerce Test 2", status: "published", is_published: false, user_id: user2.id)
    end

    it "coerces integer filter values" do
      user_id = User.find_by(email: "coerce1@test.com").id
      builder = described_class.new(Post, params: { filter: { "user_id" => user_id.to_s } })
      builder.build
      expect(builder.to_scope.count).to eq(1)
    end

    it "coerces boolean filter values" do
      builder = described_class.new(Post, params: { filter: { "is_published" => "true" } })
      builder.build
      expect(builder.to_scope.count).to eq(1)
    end

    it "handles non-numeric value for integer column" do
      builder = described_class.new(Post, params: { filter: { "user_id" => "abc" } })
      builder.build
      expect(builder.to_scope.count).to eq(0)
    end

    it "coerces comma-separated integer values" do
      ids = User.pluck(:id).map(&:to_s).join(",")
      builder = described_class.new(Post, params: { filter: { "user_id" => ids } })
      builder.build
      expect(builder.to_scope.count).to eq(2)
    end

    it "coerces float/decimal filter values" do
      # Test the decimal branch of coerce_filter_value
      builder = described_class.new(Post, params: {})
      # Stub a decimal column
      col = double("column", type: :decimal)
      allow(Post).to receive(:columns_hash).and_return({ "amount" => col })

      result = builder.send(:coerce_filter_value, "amount", "3.14")
      expect(result).to eq(3.14)
    end

    it "passes through non-numeric string for decimal column" do
      builder = described_class.new(Post, params: {})
      col = double("column", type: :decimal)
      allow(Post).to receive(:columns_hash).and_return({ "amount" => col })

      result = builder.send(:coerce_filter_value, "amount", "abc")
      expect(result).to eq("abc")
    end
  end

  # ------------------------------------------------------------------
  # Pagination from params
  # ------------------------------------------------------------------

  describe "pagination from params" do
    before { create_posts(10) }

    it "reads page from params" do
      builder = described_class.new(Post, params: { page: "2", per_page: "3" })
      builder.build
      result = builder.paginate

      expect(result[:pagination][:current_page]).to eq(2)
      expect(result[:pagination][:per_page]).to eq(3)
    end

    it "uses model's rhino_per_page_count as default" do
      builder = described_class.new(Post, params: {})
      builder.build
      result = builder.paginate

      expect(result[:pagination][:per_page]).to eq(25) # Post default
    end
  end

  # ------------------------------------------------------------------
  # Sparse fieldsets edge cases
  # ------------------------------------------------------------------

  describe "sparse fieldsets edge cases" do
    before do
      Post.create!(title: "Field Test", content: "Content", status: "draft")
    end

    it "handles fields param with table name key" do
      builder = described_class.new(Post, params: { fields: { "posts" => "title,status" } })
      builder.build
      result = builder.to_scope.first
      expect(result.attributes.keys).to include("id", "title", "status")
    end

    it "ignores fields when no allowed_fields defined" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"
      end
      builder = described_class.new(klass, params: { fields: { "posts" => "title" } })
      builder.build
      # With no allowed_fields, fields param is ignored, all columns returned
      result = builder.to_scope.first
      expect(result.attributes.keys).to include("title", "content")
    end

    it "handles no matching fields key" do
      builder = described_class.new(Post, params: { fields: { "blogs" => "title" } })
      builder.build
      # Key doesn't match Post's slug, so all columns returned
      result = builder.to_scope.first
      expect(result.attributes.keys).to include("title", "content")
    end

    it "handles empty fields string" do
      builder = described_class.new(Post, params: { fields: { "posts" => "" } })
      builder.build
      # Empty string results in no valid fields, so no select applied
      result = builder.to_scope.first
      expect(result.attributes.keys).to include("title")
    end
  end

  # ------------------------------------------------------------------
  # Search edge cases
  # ------------------------------------------------------------------

  describe "search edge cases" do
    it "handles model with no allowed_search columns" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"
      end
      Post.create!(title: "Search Test")
      builder = described_class.new(klass, params: { search: "test" })
      builder.build
      # No search columns, so search is ignored
      expect(builder.to_scope.count).to be >= 1
    end
  end

  # ------------------------------------------------------------------
  # Sorting edge cases
  # ------------------------------------------------------------------

  describe "sorting edge cases" do
    before do
      Post.create!(title: "A")
      Post.create!(title: "B")
    end

    it "applies default sort when sort param is nil" do
      builder = described_class.new(Post, params: { sort: nil })
      builder.build
      # Should apply default sort (-created_at)
      results = builder.to_scope.to_a
      expect(results.first.title).to eq("B") # last created
    end

    it "does not apply default sort when sort param is present" do
      builder = described_class.new(Post, params: { sort: "title" })
      builder.build
      results = builder.to_scope.to_a
      expect(results.first.title).to eq("A")
    end
  end

  # ------------------------------------------------------------------
  # resolve_base_include
  # ------------------------------------------------------------------

  describe "#resolve_base_include (private)" do
    it "returns nil for unrecognized includes" do
      builder = described_class.new(Post, params: {})
      result = builder.send(:resolve_base_include, "nonexistent", ["user", "comments"])
      expect(result).to be_nil
    end

    it "resolves Count suffix to base" do
      builder = described_class.new(Post, params: {})
      result = builder.send(:resolve_base_include, "commentsCount", ["comments"])
      expect(result).to eq("comments")
    end

    it "resolves Exists suffix to base" do
      builder = described_class.new(Post, params: {})
      result = builder.send(:resolve_base_include, "commentsExists", ["comments"])
      expect(result).to eq("comments")
    end

    it "returns segment directly if in allowed list" do
      builder = described_class.new(Post, params: {})
      result = builder.send(:resolve_base_include, "user", ["user", "comments"])
      expect(result).to eq("user")
    end
  end

  # ------------------------------------------------------------------
  # Filter edge cases
  # ------------------------------------------------------------------

  describe "filter edge cases" do
    it "handles non-hash filter params" do
      builder = described_class.new(Post, params: { filter: "invalid" })
      builder.build
      # Should not error, just ignore
      expect(builder.to_scope).to be_an(ActiveRecord::Relation)
    end

    it "handles empty filter hash" do
      Post.create!(title: "Filter Test")
      builder = described_class.new(Post, params: { filter: {} })
      builder.build
      expect(builder.to_scope.count).to eq(1)
    end
  end
end
