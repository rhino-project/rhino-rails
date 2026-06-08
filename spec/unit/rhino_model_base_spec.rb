# frozen_string_literal: true

require "spec_helper"
# The base class is normally pulled in by the host app; load it here so its
# class body (concern includes + default class attributes) is exercised.
require "rhino/models/rhino_model"

# Concrete subclass on an existing table so we can introspect the base behavior.
class RhinoBaseThing < Rhino::RhinoModel
  self.table_name = "posts"
end

RSpec.describe Rhino::RhinoModel do
  it "is an abstract base class" do
    expect(Rhino::RhinoModel.abstract_class).to be(true)
  end

  it "includes the core Rhino concerns" do
    [Rhino::HasRhino, Rhino::HasValidation, Rhino::HidableColumns, Rhino::HasAutoScope].each do |concern|
      expect(RhinoBaseThing.ancestors).to include(concern)
    end
  end

  it "ships sane defaults for the query DSL attributes" do
    expect(RhinoBaseThing.allowed_filters).to eq([])
    expect(RhinoBaseThing.allowed_sorts).to eq([])
    expect(RhinoBaseThing.allowed_fields).to eq([])
    expect(RhinoBaseThing.allowed_includes).to eq([])
    expect(RhinoBaseThing.allowed_search).to eq([])
    expect(RhinoBaseThing.default_sort_field).to be_nil
    expect(RhinoBaseThing.pagination_enabled).to be(false)
    expect(RhinoBaseThing.rhino_per_page_count).to eq(25)
    expect(RhinoBaseThing.rhino_model_middleware).to eq([])
    expect(RhinoBaseThing.rhino_middleware_actions_map).to eq({})
    expect(RhinoBaseThing.rhino_except_actions_list).to eq([])
    expect(RhinoBaseThing.additional_hidden_columns).to eq([])
    expect(RhinoBaseThing.rhino_owner_path).to be_nil
  end

  it "supports the configuration DSL on a subclass" do
    klass = Class.new(Rhino::RhinoModel) do
      self.table_name = "posts"
      rhino_filters :title, :status
      rhino_per_page 50
      rhino_except_actions :destroy
    end
    expect(klass.allowed_filters).to eq(%w[title status])
    expect(klass.rhino_per_page_count).to eq(50)
    expect(klass.rhino_except_actions_list).to eq(%w[destroy])
  end
end
