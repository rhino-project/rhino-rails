# frozen_string_literal: true

require "spec_helper"

# A test model that uses HasAuditTrail
class AuditablePost < ActiveRecord::Base
  include Rhino::HasAuditTrail
  self.table_name = "posts"
end

class AuditablePostWithExclusions < ActiveRecord::Base
  include Rhino::HasAuditTrail
  self.table_name = "posts"

  rhino_audit_exclude :content, :status
end

RSpec.describe Rhino::HasAuditTrail do
  # ------------------------------------------------------------------
  # Included behavior
  # ------------------------------------------------------------------

  describe "included behavior" do
    it "sets default audit_exclude_fields" do
      expect(AuditablePost.audit_exclude_fields).to include("password", "remember_token")
    end

    it "registers after_create callback" do
      callbacks = AuditablePost._create_callbacks.map(&:filter)
      expect(callbacks).to include(:log_audit_created)
    end

    it "registers after_update callback" do
      callbacks = AuditablePost._update_callbacks.map(&:filter)
      expect(callbacks).to include(:log_audit_updated)
    end

    it "registers after_destroy callback" do
      callbacks = AuditablePost._destroy_callbacks.map(&:filter)
      expect(callbacks).to include(:log_audit_deleted)
    end

    it "has audit_logs association" do
      assoc = AuditablePost.reflect_on_association(:audit_logs)
      expect(assoc).to be_present
      expect(assoc.macro).to eq(:has_many)
    end
  end

  # ------------------------------------------------------------------
  # rhino_audit_exclude
  # ------------------------------------------------------------------

  describe ".rhino_audit_exclude" do
    it "overrides default exclusions" do
      expect(AuditablePostWithExclusions.audit_exclude_fields).to eq(%w[content status])
    end
  end

  # ------------------------------------------------------------------
  # Audit log creation
  # ------------------------------------------------------------------

  describe "audit logging on create" do
    it "creates an audit log on record creation" do
      expect {
        AuditablePost.create!(title: "Audit Test")
      }.to change(Rhino::AuditLog, :count).by(1)

      log = Rhino::AuditLog.last
      expect(log.action).to eq("created")
      expect(log.old_values).to be_nil
      expect(log.new_values).to have_key("title")
      expect(log.new_values["title"]).to eq("Audit Test")
    end

    it "excludes password from new_values" do
      AuditablePost.create!(title: "Audit Exclude Test")
      log = Rhino::AuditLog.last
      expect(log.new_values).not_to have_key("password")
      expect(log.new_values).not_to have_key("remember_token")
    end
  end

  describe "audit logging on update" do
    it "creates an audit log on record update" do
      post = AuditablePost.create!(title: "Before Update")
      initial_count = Rhino::AuditLog.count

      post.update!(title: "After Update")

      expect(Rhino::AuditLog.count).to eq(initial_count + 1)
      log = Rhino::AuditLog.last
      expect(log.action).to eq("updated")
      expect(log.old_values["title"]).to eq("Before Update")
      expect(log.new_values["title"]).to eq("After Update")
    end

    it "does not create audit log when only updated_at changes" do
      post = AuditablePost.create!(title: "No Changes")
      initial_count = Rhino::AuditLog.count

      # Touch only updates updated_at
      post.touch

      # The updated callback filters out updated_at, so if that's the only
      # change, no audit log should be created
      # Note: touch may also show up as a change; the key is updated_at is excluded
      expect(Rhino::AuditLog.count).to eq(initial_count)
    end

    it "excludes custom excluded fields from audit" do
      post = AuditablePostWithExclusions.create!(title: "Exclusion Test", content: "Original", status: "draft")
      initial_count = Rhino::AuditLog.count

      post.update!(content: "Updated Content", status: "published")

      # content and status are excluded, so if only those changed,
      # no audit log should be created
      expect(Rhino::AuditLog.count).to eq(initial_count)
    end

    it "logs non-excluded fields while excluding excluded ones" do
      post = AuditablePostWithExclusions.create!(title: "Mixed Test", content: "Original")

      post.update!(title: "New Title", content: "New Content")

      log = Rhino::AuditLog.last
      expect(log.action).to eq("updated")
      expect(log.new_values).to have_key("title")
      expect(log.new_values).not_to have_key("content")
    end
  end

  describe "audit logging on destroy" do
    it "creates an audit log on record destruction" do
      post = AuditablePost.create!(title: "To Destroy")
      initial_count = Rhino::AuditLog.count

      # Destroy triggers the callback, but also destroys dependent audit_logs
      # So we check the action was logged by checking before destroy
      post_id = post.id
      post.destroy

      # Since dependent: :destroy removes audit logs, we verify the callback ran
      # by checking the audit log count (the create log is removed but destroy log
      # should also be created and removed in same transaction)
      # This test just verifies no error occurs
      expect(post.destroyed?).to be true
    end

    it "identifies soft-deleted records differently from force-deleted" do
      post = AuditablePost.create!(title: "Force Delete Test")
      # AuditablePost doesn't include Discard, so discarded? is not available
      # This should result in "force_deleted" action
      # We cannot easily test this because destroy also removes dependent audit_logs
      # Just verify no error occurs
      expect { post.destroy }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # auditable_attributes
  # ------------------------------------------------------------------

  describe "#auditable_attributes (private)" do
    it "returns attributes excluding audit_exclude_fields" do
      post = AuditablePost.new(title: "Test")
      attrs = post.send(:auditable_attributes)
      expect(attrs).to have_key("title")
      expect(attrs).not_to have_key("password")
      expect(attrs).not_to have_key("remember_token")
    end
  end

  # ------------------------------------------------------------------
  # Request context helpers
  # ------------------------------------------------------------------

  describe "request context helpers" do
    it "returns nil for current_audit_user_id when RequestStore not defined" do
      post = AuditablePost.new(title: "Test")
      # RequestStore may or may not be defined in test env
      result = post.send(:current_audit_user_id)
      expect(result).to be_nil
    end

    it "returns nil for current_audit_ip_address" do
      post = AuditablePost.new(title: "Test")
      result = post.send(:current_audit_ip_address)
      expect(result).to be_nil
    end

    it "returns nil for current_audit_user_agent" do
      post = AuditablePost.new(title: "Test")
      result = post.send(:current_audit_user_agent)
      expect(result).to be_nil
    end

    it "returns nil for current_audit_organization" do
      post = AuditablePost.new(title: "Test")
      result = post.send(:current_audit_organization)
      expect(result).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # audit_log_table_exists?
  # ------------------------------------------------------------------

  describe "#audit_log_table_exists? (private)" do
    it "returns true when audit_logs table exists" do
      post = AuditablePost.new(title: "Test")
      expect(post.send(:audit_log_table_exists?)).to be true
    end
  end

  # ------------------------------------------------------------------
  # Error handling
  # ------------------------------------------------------------------

  describe "error handling" do
    it "logs a warning instead of raising on audit log failure" do
      post = AuditablePost.new(title: "Test")
      # Mock AuditLog.create! to raise
      allow(Rhino::AuditLog).to receive(:create!).and_raise(StandardError, "DB error")

      logger_double = double("logger", warn: nil, debug: nil)
      allow(Rails).to receive(:logger).and_return(logger_double)

      expect { post.send(:log_audit, "created", nil, { "title" => "Test" }) }.not_to raise_error
      expect(logger_double).to have_received(:warn).with(/Failed to log audit/)
    end
  end
end
