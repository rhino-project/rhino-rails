# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Pagination" do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def create_posts(count, prefix: "Post")
    count.times do |i|
      Post.create!(title: "#{prefix} #{i + 1}", content: "Content #{i + 1}")
    end
  end

  # ------------------------------------------------------------------
  # Flat array without pagination
  # ------------------------------------------------------------------

  describe "flat array without pagination" do
    it "returns a flat array when no pagination params" do
      create_posts(3)

      builder = Rhino::QueryBuilder.new(Post, params: {}).build
      result = builder.paginate

      expect(result[:items].to_a.length).to eq(3)
    end

    it "returns all records when per_page is not specified" do
      create_posts(5)

      builder = Rhino::QueryBuilder.new(Post, params: {}).build
      result = builder.paginate

      expect(result[:pagination][:total]).to eq(5)
      expect(result[:items].to_a.length).to eq(5)
    end
  end

  # ------------------------------------------------------------------
  # Paginated response with headers
  # ------------------------------------------------------------------

  describe "paginated response" do
    it "returns pagination metadata" do
      create_posts(30)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "10", page: "1" }).build
      result = builder.paginate

      expect(result[:pagination][:current_page]).to eq(1)
      expect(result[:pagination][:per_page]).to eq(10)
      expect(result[:pagination][:total]).to eq(30)
      expect(result[:pagination][:last_page]).to eq(3)
      expect(result[:items].to_a.length).to eq(10)
    end

    it "navigates to second page" do
      create_posts(30)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "10", page: "2" }).build
      result = builder.paginate

      expect(result[:pagination][:current_page]).to eq(2)
      expect(result[:items].to_a.length).to eq(10)
    end

    it "returns last page correctly" do
      create_posts(25)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "10", page: "3" }).build
      result = builder.paginate

      expect(result[:pagination][:current_page]).to eq(3)
      expect(result[:pagination][:last_page]).to eq(3)
      expect(result[:items].to_a.length).to eq(5) # 25 - 20 = 5
    end
  end

  # ------------------------------------------------------------------
  # Per-page clamping
  # ------------------------------------------------------------------

  describe "per_page clamping" do
    it "clamps per_page to minimum of 1" do
      create_posts(5)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "0" }).build
      result = builder.paginate

      expect(result[:pagination][:per_page]).to eq(1)
    end

    it "clamps per_page to maximum of 100" do
      create_posts(5)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "500" }).build
      result = builder.paginate

      expect(result[:pagination][:per_page]).to eq(100)
    end

    it "clamps negative per_page to 1" do
      create_posts(5)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "-5" }).build
      result = builder.paginate

      expect(result[:pagination][:per_page]).to eq(1)
    end

    it "clamps negative page to 1" do
      create_posts(5)

      builder = Rhino::QueryBuilder.new(Post, params: { page: "-1" }).build
      result = builder.paginate

      expect(result[:pagination][:current_page]).to eq(1)
    end
  end

  # ------------------------------------------------------------------
  # Model-level per_page
  # ------------------------------------------------------------------

  describe "model-level per_page" do
    it "uses model default per_page" do
      create_posts(30)

      # Post has rhino_per_page_count = 25 by default
      builder = Rhino::QueryBuilder.new(Post, params: {}).build
      result = builder.paginate

      expect(result[:pagination][:per_page]).to eq(25)
    end

    it "per_page param overrides model default" do
      create_posts(30)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "5" }).build
      result = builder.paginate

      expect(result[:pagination][:per_page]).to eq(5)
    end
  end

  # ------------------------------------------------------------------
  # Response format consistency
  # ------------------------------------------------------------------

  describe "response format" do
    it "pagination metadata has expected keys" do
      create_posts(5)

      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "10" }).build
      result = builder.paginate

      expect(result[:pagination]).to have_key(:current_page)
      expect(result[:pagination]).to have_key(:last_page)
      expect(result[:pagination]).to have_key(:per_page)
      expect(result[:pagination]).to have_key(:total)
    end

    it "items are ActiveRecord records" do
      create_posts(3)

      builder = Rhino::QueryBuilder.new(Post, params: {}).build
      result = builder.paginate

      result[:items].each do |item|
        expect(item).to be_a(Post)
      end
    end
  end

  # ------------------------------------------------------------------
  # Empty results
  # ------------------------------------------------------------------

  describe "empty results" do
    it "returns empty items with correct metadata" do
      builder = Rhino::QueryBuilder.new(Post, params: { per_page: "10" }).build
      result = builder.paginate

      expect(result[:items].to_a).to be_empty
      expect(result[:pagination][:total]).to eq(0)
      expect(result[:pagination][:current_page]).to eq(1)
      expect(result[:pagination][:last_page]).to eq(1) # at least 1
    end
  end

  # ------------------------------------------------------------------
  # Pagination combined with other query params
  # ------------------------------------------------------------------

  describe "pagination combined with filters" do
    it "paginates filtered results" do
      8.times { |i| Post.create!(title: "Published #{i}", content: "C", status: "published") }
      3.times { |i| Post.create!(title: "Draft #{i}", content: "C", status: "draft") }

      builder = Rhino::QueryBuilder.new(Post, params: {
        filter: { "status" => "published" },
        per_page: "3",
        page: "1"
      }).build
      result = builder.paginate

      expect(result[:pagination][:total]).to eq(8)
      expect(result[:pagination][:per_page]).to eq(3)
      expect(result[:pagination][:last_page]).to eq(3)
      expect(result[:items].to_a.length).to eq(3)
    end
  end

  describe "pagination combined with search" do
    it "paginates search results" do
      10.times { |i| Post.create!(title: "Rails Guide #{i}", content: "Content") }
      5.times { |i| Post.create!(title: "Other #{i}", content: "Content") }

      builder = Rhino::QueryBuilder.new(Post, params: {
        search: "Rails",
        per_page: "3",
        page: "1"
      }).build
      result = builder.paginate

      expect(result[:pagination][:total]).to eq(10)
      expect(result[:items].to_a.length).to eq(3)
    end
  end

  describe "pagination combined with sorting" do
    it "paginates sorted results" do
      Post.create!(title: "Bravo", content: "C")
      Post.create!(title: "Alpha", content: "C")
      Post.create!(title: "Charlie", content: "C")

      builder = Rhino::QueryBuilder.new(Post, params: {
        sort: "title",
        per_page: "2",
        page: "1"
      }).build
      result = builder.paginate

      titles = result[:items].map(&:title)
      expect(titles).to eq(%w[Alpha Bravo])
    end
  end
end
