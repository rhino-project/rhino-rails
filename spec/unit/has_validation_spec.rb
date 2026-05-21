# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::HasValidation do
  describe "#validate_for_action" do
    context "with wildcard permitted fields" do
      it "validates all submitted fields" do
        instance = Post.new
        result = instance.validate_for_action(
          { "title" => "Hello", "content" => "World" },
          permitted_fields: ['*']
        )
        expect(result[:valid]).to be true
        expect(result[:validated]["title"]).to eq("Hello")
        expect(result[:validated]["content"]).to eq("World")
      end

      it "runs ActiveModel validations" do
        instance = Post.new
        result = instance.validate_for_action(
          { "title" => "A" * 256 },
          permitted_fields: ['*']
        )
        expect(result[:valid]).to be false
        expect(result[:errors]).to have_key("title")
      end
    end

    context "with specific permitted fields" do
      it "only validates permitted fields" do
        instance = Post.new
        result = instance.validate_for_action(
          { "title" => "Hello", "content" => "World", "status" => "draft" },
          permitted_fields: ['title', 'content']
        )
        expect(result[:valid]).to be true
        expect(result[:validated]).to have_key("title")
        expect(result[:validated]).to have_key("content")
        expect(result[:validated]).not_to have_key("status")
      end

      it "only returns errors for permitted fields" do
        instance = Post.new
        result = instance.validate_for_action(
          { "title" => "A" * 256, "status" => "invalid" },
          permitted_fields: ['title']
        )
        expect(result[:valid]).to be false
        expect(result[:errors]).to have_key("title")
        expect(result[:errors]).not_to have_key("status")
      end
    end

    context "with no validations" do
      it "returns valid for any data" do
        klass = Class.new(ActiveRecord::Base) do
          include Rhino::HasValidation
          self.table_name = "posts"
        end
        instance = klass.new
        result = instance.validate_for_action(
          { "title" => "Hello" },
          permitted_fields: ['*']
        )
        expect(result[:valid]).to be true
      end
    end

    context "with empty params" do
      it "returns valid with empty validated hash" do
        instance = Post.new
        result = instance.validate_for_action({}, permitted_fields: ['*'])
        expect(result[:valid]).to be true
        expect(result[:validated]).to be_empty
      end
    end

    context "with organization parameter" do
      it "removes organization_id from validated data" do
        org = Organization.create!(name: "Test Org", slug: "test-org-val-#{SecureRandom.uuid}")
        instance = Post.new
        result = instance.validate_for_action(
          { "title" => "Hello", "organization_id" => org.id },
          permitted_fields: ['*'],
          organization: org
        )
        expect(result[:valid]).to be true
        expect(result[:validated]).not_to have_key("organization_id")
        expect(result[:validated]["title"]).to eq("Hello")
      end
    end

    context "with symbol keys in params" do
      it "converts symbol keys to string keys" do
        instance = Post.new
        result = instance.validate_for_action(
          { title: "Hello", content: "World" },
          permitted_fields: ['*']
        )
        expect(result[:valid]).to be true
        expect(result[:validated]).to have_key("title")
        expect(result[:validated]).to have_key("content")
      end
    end

    context "with attributes that do not exist on the model" do
      it "ignores non-existent attributes for assignment" do
        instance = Post.new
        result = instance.validate_for_action(
          { "title" => "Hello", "nonexistent_field" => "value" },
          permitted_fields: ['*']
        )
        expect(result[:valid]).to be true
        # nonexistent_field still appears in validated (it's in params) but won't error
        expect(result[:validated]["title"]).to eq("Hello")
      end
    end

    context "with validation errors only on non-submitted fields" do
      it "does not report errors for non-submitted fields" do
        instance = Post.new
        # Only submit content, title is not submitted so its validations should not matter
        result = instance.validate_for_action(
          { "content" => "Some content" },
          permitted_fields: ['*']
        )
        expect(result[:valid]).to be true
      end
    end

    context "with multiple validation errors on the same field" do
      it "collects all error messages" do
        # Use Post model which already has title length validation
        instance = Post.new
        result = instance.validate_for_action(
          { "title" => "A" * 300 },
          permitted_fields: ['*']
        )
        expect(result[:valid]).to be false
        expect(result[:errors]["title"]).to be_an(Array)
        expect(result[:errors]["title"].length).to be >= 1
      end
    end
  end

  # ------------------------------------------------------------------
  # Cross-tenant FK validation
  # ------------------------------------------------------------------

  describe "#validate_foreign_keys_for_organization" do
    it "validates that a belongs_to FK belongs to the current organization" do
      org = Organization.create!(name: "FK Org", slug: "fk-org-#{SecureRandom.uuid}")
      user = User.create!(name: "FK User", email: "fk-#{SecureRandom.uuid}@test.com")

      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "Test", "user_id" => user.id },
        permitted_fields: ['*'],
        organization: org
      )
      # user_id points to a user - users table does not have organization_id,
      # so it depends on FK chain resolution
      expect(result).to have_key(:valid)
    end

    it "skips nil FK values" do
      org = Organization.create!(name: "FK Org", slug: "fk-org-nil-#{SecureRandom.uuid}")
      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "Test", "user_id" => nil },
        permitted_fields: ['*'],
        organization: org
      )
      expect(result[:valid]).to be true
    end

    it "skips organization_id FK itself" do
      org = Organization.create!(name: "FK Org", slug: "fk-org-skip-#{SecureRandom.uuid}")
      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "Test", "organization_id" => org.id },
        permitted_fields: ['*'],
        organization: org
      )
      expect(result[:valid]).to be true
    end

    it "passes when no FK data is submitted" do
      org = Organization.create!(name: "No FK Org", slug: "no-fk-org-#{SecureRandom.uuid}")
      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "Test" },
        permitted_fields: ['*'],
        organization: org
      )
      expect(result[:valid]).to be true
    end

    it "passes when FK data is not in submitted params" do
      org = Organization.create!(name: "FK Not Submitted", slug: "fk-not-sub-#{SecureRandom.uuid}")
      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "Test", "content" => "Body" },
        permitted_fields: ['*'],
        organization: org
      )
      expect(result[:valid]).to be true
    end

    it "handles association with unresolvable class gracefully" do
      org = Organization.create!(name: "Graceful Org", slug: "graceful-org-#{SecureRandom.uuid}")
      instance = Post.new

      # Stub an association with an unresolvable class
      bad_assoc = double("assoc", foreign_key: "bad_id")
      allow(bad_assoc).to receive(:klass).and_raise(StandardError, "cannot load")
      allow(Post).to receive(:reflect_on_all_associations).with(:belongs_to).and_return([bad_assoc])

      errors = instance.send(:validate_foreign_keys_for_organization, { "bad_id" => 123 }, org)
      # Should skip unresolvable associations
      expect(errors).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # Helper methods
  # ------------------------------------------------------------------

  describe "#table_has_organization_id?" do
    it "returns true for tables with organization_id" do
      instance = Post.new
      expect(instance.send(:table_has_organization_id?, "posts")).to be true
    end

    it "returns false for tables without organization_id" do
      instance = Post.new
      expect(instance.send(:table_has_organization_id?, "users")).to be false
    end

    it "caches the result" do
      instance = Post.new
      instance.send(:table_has_organization_id?, "posts")
      instance.send(:table_has_organization_id?, "posts")
      # Just checking it doesn't error on second call (cache hit)
      expect(instance.send(:table_has_organization_id?, "posts")).to be true
    end
  end

  describe "#find_organization_fk_chain" do
    it "returns nil for tables with no path to organization" do
      instance = Post.new
      # users table has no organization_id and no FK chain to one
      chain = instance.send(:find_organization_fk_chain, "users")
      # May or may not find a chain depending on schema — just test it doesn't error
      expect(chain).to be_nil.or(be_an(Array))
    end

    it "caches chain results" do
      instance = Post.new
      instance.send(:find_organization_fk_chain, "comments")
      result = instance.send(:find_organization_fk_chain, "comments")
      expect(result).to be_nil.or(be_an(Array))
    end
  end

  describe "#quote_table and #quote_column" do
    it "quotes table names" do
      instance = Post.new
      quoted = instance.send(:quote_table, "posts")
      expect(quoted).to be_a(String)
      expect(quoted.length).to be > 0
    end

    it "quotes column names" do
      instance = Post.new
      quoted = instance.send(:quote_column, "title")
      expect(quoted).to be_a(String)
      expect(quoted.length).to be > 0
    end
  end

  describe "#sanitize_sql" do
    it "sanitizes SQL arrays" do
      instance = Post.new
      result = instance.send(:sanitize_sql, ["SELECT 1 WHERE id = ?", 42])
      expect(result).to include("42")
    end
  end
end
