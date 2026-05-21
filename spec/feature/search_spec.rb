# frozen_string_literal: true

require "spec_helper"

class SearchablePostWithUser < ActiveRecord::Base
  include Rhino::HasRhino

  self.table_name = "posts"

  belongs_to :user, optional: true

  rhino_search "title", "user.name"
end

RSpec.describe "Search" do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def build_query(params = {})
    Rhino::QueryBuilder.new(Post, params: params).build
  end

  # ------------------------------------------------------------------
  # Basic search
  # ------------------------------------------------------------------

  describe "basic search" do
    it "returns matching rows" do
      Post.create!(title: "Rails Guide", content: "A comprehensive guide")
      Post.create!(title: "Ruby Basics", content: "Learn Ruby")
      Post.create!(title: "JavaScript 101", content: "Learn JS")

      result = build_query(search: "Rails").to_scope
      expect(result.count).to eq(1)
      expect(result.first.title).to eq("Rails Guide")
    end

    it "is case-insensitive" do
      Post.create!(title: "RAILS Guide", content: "Content")
      Post.create!(title: "rails basics", content: "Content")

      result = build_query(search: "rails").to_scope
      expect(result.count).to eq(2)
    end

    it "excludes non-matching rows" do
      Post.create!(title: "Rails Guide", content: "Content")
      Post.create!(title: "JavaScript 101", content: "Not matching at all")

      result = build_query(search: "Rails").to_scope
      titles = result.map(&:title)
      expect(titles).to include("Rails Guide")
      expect(titles).not_to include("JavaScript 101")
    end

    it "searches across multiple columns" do
      Post.create!(title: "Ruby Basics", content: "Not matching title")
      Post.create!(title: "Other", content: "Learn Rails here")

      # Post has rhino_search :title, :content
      result = build_query(search: "Rails").to_scope
      expect(result.count).to eq(1)
      expect(result.first.title).to eq("Other") # matches on content
    end
  end

  # ------------------------------------------------------------------
  # Empty / missing search
  # ------------------------------------------------------------------

  describe "empty or missing search" do
    it "returns all records when search is empty" do
      Post.create!(title: "Post 1", content: "C")
      Post.create!(title: "Post 2", content: "C")

      result = build_query(search: "").to_scope
      expect(result.count).to eq(2)
    end

    it "returns all records when search is not provided" do
      Post.create!(title: "Post 1", content: "C")
      Post.create!(title: "Post 2", content: "C")

      result = build_query({}).to_scope
      expect(result.count).to eq(2)
    end

    it "returns all records when search param is nil" do
      Post.create!(title: "Post 1", content: "C")

      result = build_query(search: nil).to_scope
      expect(result.count).to eq(1)
    end
  end

  # ------------------------------------------------------------------
  # Search composes with filters
  # ------------------------------------------------------------------

  describe "search composes with filters" do
    it "narrows results when combined with filter" do
      Post.create!(title: "Rails Guide", content: "C", status: "published")
      Post.create!(title: "Rails Advanced", content: "C", status: "draft")
      Post.create!(title: "JavaScript 101", content: "C", status: "published")

      result = build_query(search: "Rails", filter: { "status" => "published" }).to_scope
      expect(result.count).to eq(1)
      expect(result.first.title).to eq("Rails Guide")
    end
  end

  # ------------------------------------------------------------------
  # Relationship dot notation
  # ------------------------------------------------------------------

  describe "relationship dot notation" do
    it "searches through relationships using dot notation" do
      user1 = User.create!(name: "John Rails", email: "john-search@test.com")
      user2 = User.create!(name: "Jane Python", email: "jane-search@test.com")

      post1 = Post.create!(title: "Post A", content: "C", user: user1)
      post2 = Post.create!(title: "Post B", content: "C", user: user2)

      builder = Rhino::QueryBuilder.new(SearchablePostWithUser, params: { search: "Rails" }).build
      result = builder.to_scope

      expect(result.count).to eq(1)
      expect(result.first.id).to eq(post1.id)
    end
  end

  # ------------------------------------------------------------------
  # Search with pagination
  # ------------------------------------------------------------------

  describe "search with pagination" do
    it "paginates search results correctly" do
      10.times { |i| Post.create!(title: "Rails Post #{i}", content: "C") }
      5.times { |i| Post.create!(title: "Other #{i}", content: "C") }

      builder = build_query(search: "Rails", per_page: "3", page: "1")
      result = builder.paginate

      expect(result[:pagination][:total]).to eq(10)
      expect(result[:pagination][:per_page]).to eq(3)
      expect(result[:items].to_a.length).to eq(3)
    end

    it "navigates pages of search results" do
      10.times { |i| Post.create!(title: "Rails Post #{i}", content: "C") }

      builder = build_query(search: "Rails", per_page: "4", page: "3")
      result = builder.paginate

      expect(result[:pagination][:current_page]).to eq(3)
      expect(result[:items].to_a.length).to eq(2) # 10 - 8 = 2
    end
  end

  # ------------------------------------------------------------------
  # Search with sorting
  # ------------------------------------------------------------------

  describe "search with sorting" do
    it "sorts search results" do
      Post.create!(title: "Bravo Rails", content: "C")
      Post.create!(title: "Alpha Rails", content: "C")
      Post.create!(title: "Charlie Rails", content: "C")

      result = build_query(search: "Rails", sort: "title").to_scope
      titles = result.map(&:title)
      expect(titles).to eq(["Alpha Rails", "Bravo Rails", "Charlie Rails"])
    end
  end

  # ------------------------------------------------------------------
  # No search columns configured
  # ------------------------------------------------------------------

  describe "no search columns configured" do
    it "returns all records when model has no search columns" do
      blog_class = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "blogs"
      end

      Blog.create!(title: "Blog 1")
      Blog.create!(title: "Blog 2")

      # Blog has rhino_search :title but blog_class doesn't
      builder = Rhino::QueryBuilder.new(blog_class, params: { search: "Blog" }).build
      result = builder.to_scope

      # Should return all because no search columns configured on blog_class
      expect(result.count).to eq(2)
    end
  end
end
