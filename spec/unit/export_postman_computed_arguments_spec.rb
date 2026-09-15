# frozen_string_literal: true

require "spec_helper"
require "rhino/commands/export_postman_command"

# Mixes parameterless, single-parameter, multi-parameter and all-optional
# attributes so every branch of the exported request shape is covered.
class ExportArgComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HidableColumns

  self.table_name = "posts"

  def rhino_record_computed_attributes
    {
      "word_count" => ->(record, _user) { record.title.to_s.split.size },
      "label_since" => { params: [:since], with: ->(_r, _u, since) { since } },
      "label_window" => { params: %i[from to], with: ->(_r, _u, from, to) { "#{from}..#{to}" } }
    }
  end

  def self.rhino_collection_computed_attributes
    {
      "published_count" => ->(scope, _user) { scope.count },
      "draft_count" => ->(scope, _user) { scope.count },
      "status_count" => { params: [:status], with: ->(scope, _u, _s) { scope.count } },
      "range_count" => { params: %i[min max], with: ->(scope, _u, _a, _b) { scope.count } },
      "optional_count" => {
        params: [:status], optional: [:status],
        with: ->(scope, _u, _s = nil) { scope.count }
      }
    }
  end
end

# Only ONE attribute can be requested without arguments: no combined request.
class ExportArgOneFreePost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HidableColumns

  self.table_name = "posts"

  def self.rhino_collection_computed_attributes
    {
      "total_count" => ->(scope, _user) { scope.count },
      "status_count" => { params: [:status], with: ->(scope, _u, _s) { scope.count } }
    }
  end
end

RSpec.describe "Postman export — computed attribute arguments" do
  let(:command) { Rhino::Commands::ExportPostmanCommand.new }

  def folders_for(model_class, slug)
    meta = command.send(:introspect_model, model_class, slug)
    command.send(:build_action_folders, slug, meta, "")
  end

  def folder(folders, name)
    folders.find { |f| f[:name] == name }
  end

  def request(folders, folder_name, request_name)
    folder(folders, folder_name)[:item].find { |i| i[:name] == request_name }
  end

  # key => value of a request's query params
  def query(request)
    (request[:request][:url][:query] || []).to_h { |pair| [pair[:key], pair[:value]] }
  end

  let(:folders) { folders_for(ExportArgComputedPost, "export_arg_posts") }

  describe "the Computed Attributes folder" do
    it "keeps the plain list form for a parameterless attribute" do
      expect(query(request(folders, "Computed Attributes", "Computed: published_count")))
        .to eq("attributes" => "published_count")
    end

    it "uses the bare bracket form for a single-parameter attribute" do
      expect(query(request(folders, "Computed Attributes", "Computed: status_count")))
        .to eq("attributes[status_count]" => "example")
    end

    it "uses one key per parameter for a multi-parameter attribute" do
      expect(query(request(folders, "Computed Attributes", "Computed: range_count")))
        .to eq(
          "attributes[range_count][min]" => "example",
          "attributes[range_count][max]" => "example"
        )
    end

    it "still uses the bracket form for an all-optional attribute" do
      expect(query(request(folders, "Computed Attributes", "Computed: optional_count")))
        .to eq("attributes[optional_count]" => "example")
    end

    it "excludes required-parameter attributes from the combined request" do
      # status_count and range_count would be a guaranteed 403 without
      # arguments; optional_count is safe because its parameter is optional.
      expect(query(request(folders, "Computed Attributes", "Computed: multiple attributes")))
        .to eq("attributes" => "published_count,draft_count,optional_count")
    end

    it "leaves the All request with no parameters at all" do
      # A bare /computed skips required-parameter attributes server-side, so it
      # stays a valid request.
      expect(query(request(folders, "Computed Attributes", "All computed attributes"))).to eq({})
    end

    it "omits the combined request when fewer than two attributes are argument-free" do
      one_free = folders_for(ExportArgOneFreePost, "export_arg_one_free_posts")
      names = folder(one_free, "Computed Attributes")[:item].map { |i| i[:name] }

      expect(names).to include("Computed: total_count", "Computed: status_count")
      expect(names).not_to include("Computed: multiple attributes")
    end
  end

  describe "index and show" do
    it "exports the bracket form for a parameterised record attribute on index" do
      expect(query(request(folders, "Index", "With computed attribute word_count")))
        .to eq("computed_attributes" => "word_count")
      expect(query(request(folders, "Index", "With computed attribute label_since")))
        .to eq("computed_attributes[label_since]" => "example")
      expect(query(request(folders, "Index", "With computed attribute label_window")))
        .to eq(
          "computed_attributes[label_window][from]" => "example",
          "computed_attributes[label_window][to]" => "example"
        )
    end

    it "exports the bracket form for a parameterised record attribute on show" do
      expect(query(request(folders, "Show", "Show with computed attribute label_since")))
        .to eq("computed_attributes[label_since]" => "example")
      expect(query(request(folders, "Show", "Show with computed attribute label_window")))
        .to eq(
          "computed_attributes[label_window][from]" => "example",
          "computed_attributes[label_window][to]" => "example"
        )
    end
  end
end
