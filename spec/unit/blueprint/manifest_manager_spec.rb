# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/manifest_manager"
require "tmpdir"

RSpec.describe Rhino::Blueprint::ManifestManager do
  let(:tmp_dir) { Dir.mktmpdir("rhino_manifest_test") }

  after { FileUtils.remove_entry(tmp_dir) }

  it "creates manifest when none exists" do
    manager = described_class.new(tmp_dir)
    expect(manager.has_changed?("test.yaml", "abc123")).to be true
  end

  it "detects new file as changed" do
    manager = described_class.new(tmp_dir)
    expect(manager.has_changed?("new_file.yaml", "hash123")).to be true
  end

  it "detects unchanged file after recording" do
    manager = described_class.new(tmp_dir)
    hash = "abc123def456"

    manager.record_generation("contracts.yaml", hash, ["app/models/contract.rb"])
    expect(manager.has_changed?("contracts.yaml", hash)).to be false
  end

  it "detects changed file with different hash" do
    manager = described_class.new(tmp_dir)

    manager.record_generation("contracts.yaml", "old_hash", ["app/models/contract.rb"])
    expect(manager.has_changed?("contracts.yaml", "new_hash")).to be true
  end

  it "records generation with generated file paths" do
    manager = described_class.new(tmp_dir)
    files = ["app/models/contract.rb", "app/policies/contract_policy.rb"]

    manager.record_generation("contracts.yaml", "hash123", files)

    expect(manager.get_generated_files("contracts.yaml")).to eq(files)
  end

  it "returns empty array for untracked file" do
    manager = described_class.new(tmp_dir)
    expect(manager.get_generated_files("unknown.yaml")).to eq([])
  end

  it "saves and loads manifest from disk" do
    manager1 = described_class.new(tmp_dir)
    manager1.record_generation("test.yaml", "hash_abc", ["file1.rb", "file2.rb"])
    manager1.save

    manager2 = described_class.new(tmp_dir)
    expect(manager2.has_changed?("test.yaml", "hash_abc")).to be false
    expect(manager2.get_generated_files("test.yaml")).to eq(["file1.rb", "file2.rb"])
  end

  it "gets list of tracked files" do
    manager = described_class.new(tmp_dir)
    manager.record_generation("a.yaml", "hash1", [])
    manager.record_generation("b.yaml", "hash2", [])

    expect(manager.get_tracked_files).to include("a.yaml", "b.yaml")
  end

  it "removes tracking for a file" do
    manager = described_class.new(tmp_dir)
    manager.record_generation("remove_me.yaml", "hash", ["file.rb"])
    manager.remove_tracking("remove_me.yaml")

    expect(manager.has_changed?("remove_me.yaml", "hash")).to be true
    expect(manager.get_generated_files("remove_me.yaml")).to eq([])
  end

  it "handles corrupted manifest JSON gracefully" do
    File.write(File.join(tmp_dir, ".blueprint-manifest.json"), "not valid json{{{")

    manager = described_class.new(tmp_dir)
    expect(manager.has_changed?("any.yaml", "hash")).to be true
  end

  it "records generation timestamp" do
    manager = described_class.new(tmp_dir)
    before_time = Time.now.iso8601

    manager.record_generation("timed.yaml", "hash", [])
    manager.save

    raw = JSON.parse(File.read(File.join(tmp_dir, ".blueprint-manifest.json")))
    after_time = Time.now.iso8601

    expect(raw["generated_at"]).to be >= before_time
    expect(raw["generated_at"]).to be <= after_time
  end
end
