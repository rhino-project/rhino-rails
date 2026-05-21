# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/blueprint_parser"
require "tmpdir"

RSpec.describe Rhino::Blueprint::BlueprintParser do
  let(:parser) { described_class.new }
  let(:tmp_dir) { Dir.mktmpdir("rhino_parser_test") }

  after { FileUtils.remove_entry(tmp_dir) }

  def write_tmp(filename, content)
    path = File.join(tmp_dir, filename)
    File.write(path, content)
    path
  end

  # ──────────────────────────────────────────────
  # parse_roles
  # ──────────────────────────────────────────────

  describe "#parse_roles" do
    it "parses valid roles file with name and description" do
      path = write_tmp("_roles.yaml", <<~YAML)
        roles:
          owner:
            name: Owner
            description: "Full access"
          viewer:
            name: Viewer
            description: "Read-only"
      YAML

      roles = parser.parse_roles(path)

      expect(roles.keys).to contain_exactly("owner", "viewer")
      expect(roles["owner"][:name]).to eq("Owner")
      expect(roles["owner"][:description]).to eq("Full access")
      expect(roles["viewer"][:name]).to eq("Viewer")
    end

    it "throws on missing roles key" do
      path = write_tmp("bad.yaml", "something_else: true\n")
      expect { parser.parse_roles(path) }.to raise_error(/Missing 'roles' key/)
    end

    it "throws on nonexistent file" do
      expect { parser.parse_roles(File.join(tmp_dir, "nope.yaml")) }.to raise_error(/File not found/)
    end

    it "throws on empty file" do
      path = write_tmp("empty.yaml", "")
      expect { parser.parse_roles(path) }.to raise_error(/empty/)
    end

    it "throws on invalid YAML syntax" do
      path = write_tmp("bad.yaml", ":\n  : :\n  bad: [unclosed")
      expect { parser.parse_roles(path) }.to raise_error(/Invalid YAML/)
    end

    it "defaults role name from slug when name not provided" do
      path = write_tmp("default_name.yaml", <<~YAML)
        roles:
          team_lead:
            description: "Leads the team"
      YAML

      roles = parser.parse_roles(path)
      expect(roles["team_lead"][:name]).to eq("Team Lead")
    end
  end

  # ──────────────────────────────────────────────
  # parse_model
  # ──────────────────────────────────────────────

  describe "#parse_model" do
    it "parses minimal model blueprint" do
      path = write_tmp("posts.yaml", <<~YAML)
        model: Post
        columns:
          title: string
      YAML

      bp = parser.parse_model(path)

      expect(bp[:model]).to eq("Post")
      expect(bp[:columns].length).to eq(1)
      expect(bp[:columns][0][:name]).to eq("title")
      expect(bp[:columns][0][:type]).to eq("string")
    end

    it "auto-derives slug from PascalCase model name" do
      path = write_tmp("blog_posts.yaml", <<~YAML)
        model: BlogPost
        columns:
          title: string
      YAML

      bp = parser.parse_model(path)
      expect(bp[:slug]).to eq("blog_posts")
    end

    it "respects explicit slug when provided" do
      path = write_tmp("custom.yaml", <<~YAML)
        model: BlogPost
        slug: articles
        columns:
          title: string
      YAML

      bp = parser.parse_model(path)
      expect(bp[:slug]).to eq("articles")
    end

    it "parses full model with options, columns, relationships, permissions" do
      path = write_tmp("full.yaml", <<~YAML)
        model: Contract
        slug: contracts
        options:
          belongs_to_organization: true
          soft_deletes: true
        columns:
          title:
            type: string
            filterable: true
          total_value:
            type: decimal
            nullable: true
            precision: 10
            scale: 2
          uploaded_by:
            type: foreignId
            foreign_model: User
        relationships:
          - type: belongsTo
            model: User
            foreign_key: uploaded_by
        permissions:
          owner:
            actions: [index, show, store, update, destroy]
            show_fields: "*"
            create_fields: "*"
            update_fields: "*"
          viewer:
            actions: [index, show]
            show_fields: [id, title]
            hidden_fields: [total_value]
      YAML

      bp = parser.parse_model(path)

      expect(bp[:model]).to eq("Contract")
      expect(bp[:options][:belongs_to_organization]).to be true
      expect(bp[:columns].length).to eq(3)
      expect(bp[:relationships].length).to eq(1)
      expect(bp[:permissions].keys).to contain_exactly("owner", "viewer")
    end

    it "normalizes options with defaults" do
      path = write_tmp("defaults.yaml", <<~YAML)
        model: Simple
        columns:
          name: string
      YAML

      bp = parser.parse_model(path)

      expect(bp[:options][:belongs_to_organization]).to be false
      expect(bp[:options][:soft_deletes]).to be true
      expect(bp[:options][:audit_trail]).to be false
      expect(bp[:options][:owner]).to be_nil
      expect(bp[:options][:except_actions]).to eq([])
      expect(bp[:options][:pagination]).to be false
      expect(bp[:options][:per_page]).to eq(25)
    end

    it "normalizes column defaults" do
      path = write_tmp("col_defaults.yaml", <<~YAML)
        model: Item
        columns:
          name:
            type: string
      YAML

      bp = parser.parse_model(path)
      col = bp[:columns][0]

      expect(col[:name]).to eq("name")
      expect(col[:type]).to eq("string")
      expect(col[:nullable]).to be false
      expect(col[:unique]).to be false
      expect(col[:index]).to be false
      expect(col[:default]).to be_nil
      expect(col[:filterable]).to be false
      expect(col[:sortable]).to be false
      expect(col[:searchable]).to be false
      expect(col[:precision]).to be_nil
      expect(col[:scale]).to be_nil
      expect(col[:foreign_model]).to be_nil
    end

    it "throws on missing model key" do
      path = write_tmp("no_model.yaml", <<~YAML)
        slug: things
        columns:
          name: string
      YAML

      expect { parser.parse_model(path) }.to raise_error(/Missing 'model' key/)
    end

    it "handles wildcard show_fields" do
      path = write_tmp("wildcard.yaml", <<~YAML)
        model: Widget
        columns:
          name: string
        permissions:
          admin:
            actions: [index, show]
            show_fields: "*"
      YAML

      bp = parser.parse_model(path)
      expect(bp[:permissions]["admin"][:show_fields]).to eq(["*"])
    end

    it "handles empty create_fields correctly" do
      path = write_tmp("empty_fields.yaml", <<~YAML)
        model: ReadOnly
        columns:
          name: string
        permissions:
          viewer:
            actions: [index, show]
            show_fields: [name]
            create_fields: []
            update_fields: []
      YAML

      bp = parser.parse_model(path)
      expect(bp[:permissions]["viewer"][:create_fields]).to eq([])
      expect(bp[:permissions]["viewer"][:update_fields]).to eq([])
    end
  end

  # ──────────────────────────────────────────────
  # compute_file_hash
  # ──────────────────────────────────────────────

  describe "#compute_file_hash" do
    it "computes consistent 64-char SHA-256 hash" do
      path = write_tmp("hashable.yaml", "model: Test\n")

      hash1 = parser.compute_file_hash(path)
      hash2 = parser.compute_file_hash(path)

      expect(hash1.length).to eq(64)
      expect(hash1).to eq(hash2)
      expect(hash1).to match(/\A[a-f0-9]{64}\z/)
    end

    it "hash changes when content changes" do
      path = write_tmp("changing.yaml", "model: Original\n")
      hash1 = parser.compute_file_hash(path)

      File.write(path, "model: Modified\n")
      hash2 = parser.compute_file_hash(path)

      expect(hash1).not_to eq(hash2)
    end
  end
end
