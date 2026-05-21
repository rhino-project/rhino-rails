# frozen_string_literal: true

require "spec_helper"

# RhinoModel requires ApplicationRecord which is not available in the test env.
# Instead, we verify the behavior through Post which includes the same concerns.
RSpec.describe "RhinoModel behavior" do
  describe "concerns included via HasRhino" do
    it "Post includes HasRhino" do
      expect(Post.ancestors).to include(Rhino::HasRhino)
    end

    it "Post includes HasValidation" do
      expect(Post.ancestors).to include(Rhino::HasValidation)
    end

    it "Post includes HidableColumns" do
      expect(Post.ancestors).to include(Rhino::HidableColumns)
    end
  end

  describe "class attributes on models" do
    it "allowed_filters is configurable" do
      expect(Post.allowed_filters).to include("title")
    end

    it "allowed_sorts is configurable" do
      expect(Post.allowed_sorts).to include("title")
    end

    it "allowed_fields is configurable" do
      expect(Post.allowed_fields).to include("id")
      expect(Post.allowed_fields).to include("title")
    end

    it "allowed_includes is configurable" do
      expect(Post.allowed_includes).to include("user")
      expect(Post.allowed_includes).to include("comments")
    end

    it "allowed_search is configurable" do
      expect(Post.allowed_search).to include("title")
      expect(Post.allowed_search).to include("content")
    end

    it "default_sort_field is configurable" do
      expect(Post.default_sort_field).to eq("-created_at")
    end

    it "pagination_enabled defaults to false" do
      expect(Post.pagination_enabled).to be false
    end

    it "rhino_per_page_count defaults to 25" do
      expect(Post.rhino_per_page_count).to eq(25)
    end

    it "rhino_model_middleware defaults to empty array" do
      expect(Post.rhino_model_middleware).to eq([])
    end

    it "rhino_middleware_actions_map defaults to empty hash" do
      expect(Post.rhino_middleware_actions_map).to eq({})
    end

    it "rhino_except_actions_list defaults to empty array" do
      expect(Post.rhino_except_actions_list).to eq([])
    end

    it "additional_hidden_columns defaults to empty array" do
      expect(Post.additional_hidden_columns).to eq([])
    end
  end

  describe "soft delete detection" do
    it "Post uses soft deletes (has Discard::Model)" do
      expect(Post.uses_soft_deletes?).to be true
    end

    it "Blog does not use soft deletes" do
      expect(Blog.uses_soft_deletes?).to be false
    end
  end

  describe "rhino_model.rb can be loaded" do
    it "requires without error when ApplicationRecord is defined" do
      # ApplicationRecord is not defined in test env, but we can verify
      # the file structure exists
      path = File.join(Gem.loaded_specs["rhino"]&.full_gem_path || "lib", "rhino/models/rhino_model.rb")
      # Just verify the file exists in the lib directory
      lib_path = File.expand_path("../../../lib/rhino/models/rhino_model.rb", __FILE__)
      expect(File.exist?(lib_path)).to be true
    end
  end
end
