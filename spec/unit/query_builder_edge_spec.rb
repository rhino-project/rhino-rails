# frozen_string_literal: true

require "spec_helper"

# Edge cases for the query builder beyond the happy-path spec: pagination
# clamping, params-driven per_page, empty-result metadata, and allowlist
# enforcement for sorts/filters.
RSpec.describe Rhino::QueryBuilder do
  before do
    Post.delete_all
    10.times { |i| Post.create!(title: "P#{i}", status: "published") }
  end

  describe "pagination clamping" do
    def built
      b = described_class.new(Post, params: {})
      b.build
      b
    end

    it "clamps per_page below 1 up to 1" do
      expect(built.paginate(per_page: 0)[:pagination][:per_page]).to eq(1)
    end

    it "clamps per_page above 100 down to 100" do
      expect(built.paginate(per_page: 500)[:pagination][:per_page]).to eq(100)
    end

    it "clamps a non-positive page up to 1" do
      expect(built.paginate(per_page: 5, page: -3)[:pagination][:current_page]).to eq(1)
    end

    it "reports last_page >= 1 and empty items for an empty result set" do
      Post.delete_all
      result = built.paginate(per_page: 5)
      expect(result[:pagination][:last_page]).to eq(1)
      expect(result[:pagination][:total]).to eq(0)
      expect(result[:items].to_a).to eq([])
    end

    it "reads per_page from the request params" do
      builder = described_class.new(Post, params: { per_page: "3" })
      builder.build
      expect(builder.paginate[:pagination][:per_page]).to eq(3)
    end

    it "returns metadata consistent with the data on a middle page" do
      result = built.paginate(per_page: 4, page: 2)
      expect(result[:pagination]).to include(current_page: 2, per_page: 4, total: 10, last_page: 3)
      expect(result[:items].to_a.size).to eq(4)
    end
  end

  describe "allowlist enforcement" do
    it "ignores a sort field that is not in allowed_sorts" do
      builder = described_class.new(Post, params: { sort: "content" }) # content is not sortable
      expect { builder.build }.not_to raise_error
      expect(builder.to_scope.count).to eq(10)
    end

    it "ignores a filter field that is not in allowed_filters" do
      builder = described_class.new(Post, params: { filter: { "content" => "nope" } })
      builder.build
      expect(builder.to_scope.count).to eq(10)
    end

    it "applies an allowed filter and an allowed sort together" do
      Post.create!(title: "AAA", status: "draft")
      builder = described_class.new(Post, params: { filter: { "status" => "draft" }, sort: "title" })
      builder.build
      expect(builder.to_scope.pluck(:status).uniq).to eq(["draft"])
    end
  end
end
