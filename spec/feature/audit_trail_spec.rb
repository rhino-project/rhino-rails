# frozen_string_literal: true

require "spec_helper"

# --------------------------------------------------------------------------
# Test Models
# --------------------------------------------------------------------------

class AuditPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAuditTrail
  include Discard::Model

  self.table_name = "posts"

  belongs_to :user, optional: true
end

class AuditPostWithExclusions < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAuditTrail

  self.table_name = "posts"

  rhino_audit_exclude :password, :remember_token, :status
end

class AuditPostMinimal < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAuditTrail

  self.table_name = "posts"

  # No rhino_audit_exclude, no Discard — minimal usage
end

RSpec.describe "AuditTrail" do
  # ------------------------------------------------------------------
  # Logging on model events
  # ------------------------------------------------------------------

  describe "logging on model events" do
    it "logs created event" do
      post = AuditPost.create!(title: "New Post", content: "Body")

      logs = Rhino::AuditLog.where(
        auditable_type: "AuditPost",
        auditable_id: post.id
      )

      expect(logs.count).to eq(1)
      expect(logs.first.action).to eq("created")
      expect(logs.first.old_values).to be_nil
      expect(logs.first.new_values["title"]).to eq("New Post")
    end

    it "logs updated event with only dirty fields" do
      post = AuditPost.create!(title: "Original", content: "Body")

      # Clear the "created" log
      Rhino::AuditLog.delete_all

      post.update!(title: "Changed")

      logs = Rhino::AuditLog.where(
        auditable_type: "AuditPost",
        auditable_id: post.id
      )

      expect(logs.count).to eq(1)
      expect(logs.first.action).to eq("updated")
      expect(logs.first.old_values["title"]).to eq("Original")
      expect(logs.first.new_values["title"]).to eq("Changed")

      # Content was NOT changed, so it should NOT be in old/new values
      expect(logs.first.old_values).not_to have_key("content")
      expect(logs.first.new_values).not_to have_key("content")
    end

    it "does not log update when nothing changed" do
      post = AuditPost.create!(title: "Same", content: "Body")
      Rhino::AuditLog.delete_all

      # "Update" with the same values
      post.title = "Same"
      post.save!

      expect(Rhino::AuditLog.count).to eq(0)
    end

    it "logs deleted event" do
      post = AuditPost.create!(title: "To Delete", content: "Body")
      Rhino::AuditLog.delete_all

      # For Discard, destroy means actual deletion, discard means soft delete
      post.destroy!

      logs = Rhino::AuditLog.where(action: "force_deleted")
      expect(logs.count).to eq(1)
      expect(logs.first.old_values["title"]).to eq("To Delete")
      expect(logs.first.new_values).to be_nil
    end

    it "logs soft-deleted (discarded) event" do
      post = AuditPost.create!(title: "To Discard", content: "Body")
      Rhino::AuditLog.delete_all

      post.discard!

      # The after_destroy callback fires on discard when using Discard
      # The exact action depends on whether discarded? returns true at destroy time
      logs = Rhino::AuditLog.where(auditable_type: "AuditPost", auditable_id: post.id)
      expect(logs.count).to be >= 1
    end
  end

  # ------------------------------------------------------------------
  # Excluded columns
  # ------------------------------------------------------------------

  describe "excluded columns" do
    it "does not log excluded columns on create" do
      post = AuditPostWithExclusions.create!(
        title: "Post",
        content: "Body",
        status: "published"
      )

      log = Rhino::AuditLog.where(auditable_type: "AuditPostWithExclusions").first
      expect(log.new_values).not_to have_key("status")
      expect(log.new_values).to have_key("title")
    end

    it "does not log excluded columns on update" do
      post = AuditPostWithExclusions.create!(
        title: "Post",
        status: "draft"
      )
      Rhino::AuditLog.delete_all

      post.update!(title: "New Title", status: "published")

      log = Rhino::AuditLog.first

      # Title should be logged
      expect(log.old_values["title"]).to eq("Post")
      expect(log.new_values["title"]).to eq("New Title")

      # Status should NOT be logged
      expect(log.old_values).not_to have_key("status")
      expect(log.new_values).not_to have_key("status")
    end
  end

  # ------------------------------------------------------------------
  # User and metadata tracking
  # ------------------------------------------------------------------

  describe "user and metadata tracking" do
    it "logs nil user for unauthenticated" do
      AuditPost.create!(title: "No Auth", content: "Body")

      log = Rhino::AuditLog.first
      expect(log.user_id).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # morphMany relationship
  # ------------------------------------------------------------------

  describe "audit_logs relationship" do
    it "returns audit logs via relationship" do
      post = AuditPost.create!(title: "Relationship", content: "Body")
      post.update!(title: "Changed")

      logs = post.audit_logs
      expect(logs.count).to eq(2)
      expect(logs.map(&:action)).to contain_exactly("created", "updated")
    end
  end

  # ------------------------------------------------------------------
  # Full lifecycle
  # ------------------------------------------------------------------

  describe "full CRUD lifecycle audit trail" do
    it "logs all lifecycle events" do
      # Create
      post = AuditPost.create!(title: "Lifecycle", content: "Original")

      # Update
      post.update!(title: "Lifecycle Updated", content: "Changed")

      # Count all logs
      logs = post.audit_logs.reorder(created_at: :asc)
      actions = logs.map(&:action)

      expect(actions).to include("created")
      expect(actions).to include("updated")
    end
  end

  # ------------------------------------------------------------------
  # Regression: model without custom audit exclusions
  # ------------------------------------------------------------------

  describe "model without custom audit exclusions" do
    it "does not crash on create" do
      post = AuditPostMinimal.create!(title: "Minimal", content: "Body")

      logs = Rhino::AuditLog.where(
        auditable_type: "AuditPostMinimal",
        auditable_id: post.id
      )

      expect(logs.count).to eq(1)
      expect(logs.first.action).to eq("created")
      expect(logs.first.new_values["title"]).to eq("Minimal")
    end

    it "uses default excluded fields" do
      expect(AuditPostMinimal.audit_exclude_fields).to eq(%w[password remember_token])
    end

    it "logs update correctly" do
      post = AuditPostMinimal.create!(title: "Original", content: "Body")
      Rhino::AuditLog.delete_all

      post.update!(title: "Changed")

      log = Rhino::AuditLog.first
      expect(log).not_to be_nil
      expect(log.action).to eq("updated")
      expect(log.old_values["title"]).to eq("Original")
      expect(log.new_values["title"]).to eq("Changed")
    end

    it "logs delete correctly" do
      post = AuditPostMinimal.create!(title: "Delete Me", content: "Body")
      Rhino::AuditLog.delete_all

      post.destroy!

      log = Rhino::AuditLog.first
      expect(log).not_to be_nil
      expect(log.action).to eq("force_deleted")
      expect(log.old_values["title"]).to eq("Delete Me")
    end
  end

  # ------------------------------------------------------------------
  # Default audit exclusions
  # ------------------------------------------------------------------

  describe "default audit exclusions" do
    it "has default excluded fields" do
      expect(AuditPost.audit_exclude_fields).to include("password", "remember_token")
    end

    it "allows custom exclusions" do
      expect(AuditPostWithExclusions.audit_exclude_fields).to include("status")
    end
  end
end
