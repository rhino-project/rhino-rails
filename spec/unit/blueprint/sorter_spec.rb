# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/sorter"

# Exhaustive coverage for dependency-aware migration ordering: parents (referenced
# tables) must be emitted before children (the models that foreign-key to them).
RSpec.describe Rhino::Blueprint::Sorter do
  let(:sorter) { described_class.new }

  # Build a blueprint with foreignId columns to each model in fk_models, plus any
  # extra raw columns.
  def bp(model, fk_models = [], extra_columns = [])
    columns = fk_models.map do |fk|
      { name: "#{fk.downcase}_id", type: "foreignId", foreign_model: fk }
    end + extra_columns
    { model: model, table: "#{model.downcase}s", columns: columns }
  end

  def names(blueprints)
    blueprints.map { |b| b[:model] }
  end

  def assert_before(parent, child, ordered)
    expect(ordered.index(parent)).to be < ordered.index(child),
                                     "expected #{parent} (parent) before #{child} (child)"
  end

  def assert_same_model_set(input, output)
    expect(names(output).sort).to eq(names(input).sort)
  end

  # ── degenerate inputs ────────────────────────────────────────────────

  it "returns empty for empty input" do
    expect(sorter.sort([])).to eq([])
    expect(sorter.cycles).to eq([])
  end

  it "leaves a single model unchanged" do
    out = sorter.sort([bp("Post")])
    expect(names(out)).to eq(["Post"])
    expect(sorter.cycles).to eq([])
  end

  # ── independents: stable order preserved ─────────────────────────────

  it "keeps input order for independent models" do
    out = sorter.sort([bp("Apple"), bp("Banana"), bp("Cherry")])
    expect(names(out)).to eq(%w[Apple Banana Cherry])
    expect(sorter.cycles).to eq([])
  end

  # ── linear chain ─────────────────────────────────────────────────────

  it "orders a linear chain parents-first" do
    out = names(sorter.sort([bp("Comment", ["Post"]), bp("Post", ["Blog"]), bp("Blog")]))
    expect(out).to eq(%w[Blog Post Comment])
    expect(sorter.cycles).to eq([])
  end

  it "handles a forward reference (child before parent in input)" do
    out = names(sorter.sort([bp("Comment", ["Post"]), bp("Post")]))
    expect(out).to eq(%w[Post Comment])
    expect(sorter.cycles).to eq([])
  end

  # ── diamond ──────────────────────────────────────────────────────────

  it "orders a diamond dependency" do
    # D -> B, D -> C, B -> A, C -> A
    out = names(sorter.sort([bp("D", %w[B C]), bp("C", ["A"]), bp("B", ["A"]), bp("A")]))
    assert_before("A", "B", out)
    assert_before("A", "C", out)
    assert_before("B", "D", out)
    assert_before("C", "D", out)
    expect(out.first).to eq("A")
    expect(out.last).to eq("D")
    expect(sorter.cycles).to eq([])
  end

  # ── mixed independents + chains ──────────────────────────────────────

  it "orders chains while keeping independents in relative order" do
    input = [bp("Alpha"), bp("Comment", ["Post"]), bp("Post", ["Blog"]), bp("Zeta"), bp("Blog")]
    out = names(sorter.sort(input))
    assert_before("Blog", "Post", out)
    assert_before("Post", "Comment", out)
    assert_before("Alpha", "Zeta", out)
    assert_same_model_set(input, sorter.sort(input))
  end

  # ── references that impose NO ordering ───────────────────────────────

  it "treats a self-reference as neither a dependency nor a cycle" do
    out = names(sorter.sort([bp("Category", ["Category"]), bp("Tag")]))
    expect(out).to eq(%w[Category Tag])
    expect(sorter.cycles).to eq([])
  end

  it "ignores references to models outside the generation set" do
    # Post -> Organization, created by rhino:install, not in this set.
    out = names(sorter.sort([bp("Post", ["Organization"]), bp("Comment")]))
    expect(out).to eq(%w[Post Comment])
    expect(sorter.cycles).to eq([])
  end

  it "does not order on a foreign_model attached to a non-foreignId column" do
    input = [bp("Beta", [], [{ name: "x", type: "string", foreign_model: "Alpha" }]), bp("Alpha")]
    out = names(sorter.sort(input))
    expect(out).to eq(%w[Beta Alpha])
    expect(sorter.cycles).to eq([])
  end

  it "counts duplicate FKs to the same parent once" do
    out = names(sorter.sort([bp("Match", %w[Team Team]), bp("Team")]))
    expect(out).to eq(%w[Team Match])
    expect(sorter.cycles).to eq([])
  end

  # ── cycles ───────────────────────────────────────────────────────────

  it "detects a direct cycle and still returns all models" do
    input = [bp("A", ["B"]), bp("B", ["A"])]
    out = sorter.sort(input)
    assert_same_model_set(input, out)
    expect(out.length).to eq(2)
    expect(sorter.cycles).to include("A", "B")
  end

  it "detects a three-node cycle" do
    input = [bp("A", ["B"]), bp("B", ["C"]), bp("C", ["A"])]
    out = sorter.sort(input)
    assert_same_model_set(input, out)
    expect(sorter.cycles).not_to be_empty
  end

  it "keeps a downstream dependent out of the cycle and after it" do
    # A <-> B cycle; C -> A depends on the cycle.
    input = [bp("A", ["B"]), bp("B", ["A"]), bp("C", ["A"])]
    out = names(sorter.sort(input))
    assert_same_model_set(input, sorter.sort(input))
    assert_before("A", "C", out)
    expect(sorter.cycles).not_to include("C")
  end

  it "detects two independent cycles" do
    input = [bp("A", ["B"]), bp("B", ["A"]), bp("X", ["Y"]), bp("Y", ["X"])]
    sorter.sort(input)
    expect(sorter.cycles).to include("A", "B", "X", "Y")
  end

  # ── determinism ──────────────────────────────────────────────────────

  it "is idempotent" do
    input = [bp("Comment", ["Post"]), bp("Post", ["Blog"]), bp("Blog"), bp("Tag")]
    once = sorter.sort(input)
    twice = sorter.sort(once)
    expect(names(once)).to eq(names(twice))
  end

  it "resets cycles between runs" do
    sorter.sort([bp("A", ["B"]), bp("B", ["A"])])
    expect(sorter.cycles).not_to be_empty
    sorter.sort([bp("Blog"), bp("Post", ["Blog"])])
    expect(sorter.cycles).to eq([])
  end
end
