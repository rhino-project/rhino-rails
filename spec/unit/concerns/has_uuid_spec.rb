# frozen_string_literal: true

require "spec_helper"

# A table with a `uuid` column for exercising Rhino::HasUuid, plus a model on the
# uuid-less `posts` table to cover the `respond_to?(:uuid=)` guard.
ActiveRecord::Base.connection.create_table(:uuid_widgets, force: true) do |t|
  t.string :uuid
  t.string :name
  t.timestamps
end

class UuidWidget < ActiveRecord::Base
  include Rhino::HasUuid
end

class NoUuidPost < ActiveRecord::Base
  self.table_name = "posts"
  include Rhino::HasUuid
end

RSpec.describe Rhino::HasUuid do
  it "generates a UUID on create" do
    widget = UuidWidget.create!(name: "a")
    expect(widget.uuid).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "preserves a pre-set UUID (does not overwrite)" do
    widget = UuidWidget.create!(name: "a", uuid: "preset-uuid-value")
    expect(widget.uuid).to eq("preset-uuid-value")
  end

  it "generates the UUID only on create, never on update" do
    widget = UuidWidget.create!(name: "a")
    original = widget.uuid
    widget.update!(name: "b")
    expect(widget.uuid).to eq(original)
  end

  it "generates distinct UUIDs across records" do
    a = UuidWidget.create!(name: "a")
    b = UuidWidget.create!(name: "b")
    expect(a.uuid).not_to eq(b.uuid)
  end

  it "is a no-op (no error) for a model without a uuid column" do
    expect { NoUuidPost.create!(title: "x") }.not_to raise_error
  end
end
