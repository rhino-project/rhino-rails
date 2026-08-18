# frozen_string_literal: true

require "spec_helper"
require "rhino/commands/export_postman_command"

# Models used purely for exporter introspection (bound to the shared `posts` table).
class ExportComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HidableColumns

  self.table_name = "posts"

  def rhino_record_computed_attributes
    { "word_count" => ->(record, _user) { record.title.to_s.split.size } }
  end

  def self.rhino_collection_computed_attributes
    {
      "published_count" => ->(scope, _user) { scope.where(is_published: true).count },
      "draft_count" => ->(scope, _user) { scope.where(is_published: false).count }
    }
  end
end

class ExportComputedExceptedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HidableColumns

  self.table_name = "posts"

  rhino_except_actions :computed

  def self.rhino_collection_computed_attributes
    { "published_count" => ->(scope, _user) { scope.count } }
  end
end

class ExportPlainPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HidableColumns

  self.table_name = "posts"
end

RSpec.describe "Postman export — computed attributes" do
  let(:command) { Rhino::Commands::ExportPostmanCommand.new }

  def folders_for(model_class, slug)
    meta = command.send(:introspect_model, model_class, slug)
    command.send(:build_action_folders, slug, meta, "")
  end

  def folder(folders, name)
    folders.find { |f| f[:name] == name }
  end

  def raw_url(request)
    request[:request][:url][:raw]
  end

  describe "introspection" do
    it "collects the declared collection attribute names" do
      meta = command.send(:introspect_model, ExportComputedPost, "export_computed_posts")

      expect(meta[:collection_computed_attributes]).to eq(%w[published_count draft_count])
    end

    it "collects the declared record attribute names" do
      meta = command.send(:introspect_model, ExportComputedPost, "export_computed_posts")

      expect(meta[:record_computed_attributes]).to eq(%w[word_count])
    end

    it "returns empty lists for a model that declares nothing" do
      meta = command.send(:introspect_model, ExportPlainPost, "export_plain_posts")

      expect(meta[:collection_computed_attributes]).to eq([])
      expect(meta[:record_computed_attributes]).to eq([])
    end
  end

  describe "the Computed Attributes folder" do
    it "is exported for a declaring model" do
      folders = folders_for(ExportComputedPost, "export_computed_posts")
      computed = folder(folders, "Computed Attributes")

      expect(computed).not_to be_nil
      expect(computed[:item].map { |r| r[:name] }).to eq(
        [
          "All computed attributes",
          "Computed: published_count",
          "Computed: draft_count",
          "Computed: multiple attributes"
        ]
      )
    end

    it "targets the /computed endpoint" do
      folders = folders_for(ExportComputedPost, "export_computed_posts")
      requests = folder(folders, "Computed Attributes")[:item]

      all = requests.find { |r| r[:name] == "All computed attributes" }
      one = requests.find { |r| r[:name] == "Computed: published_count" }
      many = requests.find { |r| r[:name] == "Computed: multiple attributes" }

      expect(raw_url(all)).to include("/export_computed_posts/computed")
      expect(raw_url(all)).not_to include("attributes=")
      expect(raw_url(one)).to include("attributes=published_count")
      expect(raw_url(many)).to include("attributes=published_count,draft_count")
      expect(all[:request][:method]).to eq("GET")
    end

    it "is absent for a model that declares nothing" do
      folders = folders_for(ExportPlainPost, "export_plain_posts")

      expect(folder(folders, "Computed Attributes")).to be_nil
    end

    it "is absent when the action is excepted" do
      folders = folders_for(ExportComputedExceptedPost, "export_excepted_posts")

      expect(folder(folders, "Computed Attributes")).to be_nil
      expect(folder(folders, "Index")).not_to be_nil
    end
  end

  describe "record-level examples" do
    it "adds a ?computed_attributes= example to Index" do
      folders = folders_for(ExportComputedPost, "export_computed_posts")
      request = folder(folders, "Index")[:item].find { |r| r[:name] == "With computed attribute word_count" }

      expect(request).not_to be_nil
      expect(raw_url(request)).to include("computed_attributes=word_count")
    end

    it "adds a ?computed_attributes= example to Show" do
      folders = folders_for(ExportComputedPost, "export_computed_posts")
      request = folder(folders, "Show")[:item].find { |r| r[:name] == "Show with computed attribute word_count" }

      expect(request).not_to be_nil
      expect(raw_url(request)).to include("computed_attributes=word_count")
    end

    it "adds none for a model that declares nothing" do
      folders = folders_for(ExportPlainPost, "export_plain_posts")
      names = folder(folders, "Index")[:item].map { |r| r[:name] }

      expect(names.grep(/computed attribute/)).to be_empty
    end
  end

  describe "backward compatibility" do
    it "tolerates a meta hash without the new keys" do
      meta = {
        slug: "legacy",
        except_actions: [],
        uses_soft_deletes: false,
        allowed_filters: [],
        allowed_sorts: [],
        allowed_fields: [],
        allowed_includes: [],
        allowed_search: [],
        default_sort: nil
      }

      expect { command.send(:build_action_folders, "legacy", meta, "") }.not_to raise_error
    end
  end
end
