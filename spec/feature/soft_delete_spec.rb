# frozen_string_literal: true

require "spec_helper"

# --------------------------------------------------------------------------
# Test Models
# --------------------------------------------------------------------------

class SoftDeletePost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Discard::Model

  self.table_name = "posts"

  belongs_to :user, optional: true

  rhino_filters :title, :status
  rhino_sorts :title, :created_at
end

class NonSoftDeleteModel < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "blogs"
end

RSpec.describe "SoftDelete" do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def create_post(title: "Test Post", user_id: nil)
    SoftDeletePost.create!(title: title, content: "Content for #{title}", user_id: user_id)
  end

  def create_and_discard_post(title: "Deleted Post", user_id: nil)
    post = create_post(title: title, user_id: user_id)
    post.discard!
    post
  end

  # ------------------------------------------------------------------
  # Soft delete detection
  # ------------------------------------------------------------------

  describe "soft delete detection" do
    it "detects soft deletes on model with discarded_at" do
      expect(SoftDeletePost.uses_soft_deletes?).to be true
    end

    it "detects no soft deletes on model without discarded_at" do
      expect(NonSoftDeleteModel.uses_soft_deletes?).to be false
    end
  end

  # ------------------------------------------------------------------
  # Trashed — List soft-deleted records
  # ------------------------------------------------------------------

  describe "trashed listing" do
    it "returns only discarded records" do
      create_post(title: "Active Post")
      create_and_discard_post(title: "Deleted Post 1")
      create_and_discard_post(title: "Deleted Post 2")

      trashed = SoftDeletePost.discarded
      expect(trashed.count).to eq(2)
      expect(trashed.map(&:title)).to contain_exactly("Deleted Post 1", "Deleted Post 2")
    end

    it "does not return active records" do
      create_post(title: "Active Post 1")
      create_post(title: "Active Post 2")

      trashed = SoftDeletePost.discarded
      expect(trashed.count).to eq(0)
    end

    it "returns empty when no deleted records" do
      trashed = SoftDeletePost.discarded
      expect(trashed.count).to eq(0)
    end

    it "supports pagination on trashed records" do
      8.times { |i| create_and_discard_post(title: "Deleted Post #{i + 1}") }

      builder = Rhino::QueryBuilder.new(SoftDeletePost.discarded, params: { per_page: "3" })
      # Since we pass an already-scoped relation, we paginate directly
      total = SoftDeletePost.discarded.count
      expect(total).to eq(8)
    end
  end

  # ------------------------------------------------------------------
  # Restore — Bring back a soft-deleted record
  # ------------------------------------------------------------------

  describe "restore" do
    it "restores a discarded record" do
      post = create_and_discard_post(title: "To Restore")
      expect(post.discarded?).to be true

      post.undiscard!
      post.reload

      expect(post.discarded?).to be false
      expect(post.discarded_at).to be_nil
    end

    it "restored record appears in kept scope" do
      post = create_and_discard_post(title: "To Restore")
      post.undiscard!

      kept = SoftDeletePost.kept
      expect(kept.map(&:id)).to include(post.id)
    end

    it "cannot undiscard an already active record" do
      post = create_post(title: "Active Post")
      expect(post.discarded?).to be false

      # Undiscarding an active record is a no-op
      result = post.undiscard
      expect(result).to be_falsey # already undiscarded
    end
  end

  # ------------------------------------------------------------------
  # Force delete — Permanently remove
  # ------------------------------------------------------------------

  describe "force delete" do
    it "permanently removes a discarded record" do
      post = create_and_discard_post(title: "To Be Gone")
      post_id = post.id

      post.destroy!

      expect(SoftDeletePost.unscoped.exists?(post_id)).to be false
    end

    it "permanently removes without trace" do
      post = create_and_discard_post(title: "Gone Forever")

      post.destroy!

      expect(SoftDeletePost.discarded.count).to eq(0)
      expect(SoftDeletePost.kept.count).to eq(0)
    end
  end

  # ------------------------------------------------------------------
  # Standard destroy still soft-deletes
  # ------------------------------------------------------------------

  describe "standard discard" do
    it "discard soft-deletes (not permanent)" do
      post = create_post(title: "Soft Delete Me")

      post.discard!

      # Record should still exist but be discarded
      expect(SoftDeletePost.unscoped.exists?(post.id)).to be true
      expect(post.reload.discarded?).to be true

      # It should show up in discarded scope
      trashed = SoftDeletePost.discarded
      expect(trashed.count).to eq(1)
      expect(trashed.first.title).to eq("Soft Delete Me")
    end
  end

  # ------------------------------------------------------------------
  # Full lifecycle: create -> discard -> trashed -> restore -> force-delete
  # ------------------------------------------------------------------

  describe "full soft delete lifecycle" do
    it "follows complete lifecycle" do
      # 1. Create
      post = create_post(title: "Lifecycle Post")
      expect(post.discarded_at).to be_nil

      # 2. Soft delete (discard)
      post.discard!
      expect(post.discarded?).to be true

      # 3. Visible in trashed
      expect(SoftDeletePost.discarded.count).to eq(1)

      # 4. Not visible in kept
      expect(SoftDeletePost.kept.count).to eq(0)

      # 5. Restore
      post.undiscard!
      expect(post.reload.discarded?).to be false

      # 6. Visible in kept again
      expect(SoftDeletePost.kept.count).to eq(1)

      # 7. Soft delete again
      post.discard!

      # 8. Force delete (permanent)
      post.destroy!
      expect(SoftDeletePost.unscoped.where(id: post.id).count).to eq(0)
    end
  end

  # ------------------------------------------------------------------
  # Permission checks (policy-level)
  # ------------------------------------------------------------------

  describe "permission checks" do
    def create_user_with_permissions(permissions)
      user = User.create!(name: "SD User", email: "sd-user-#{SecureRandom.uuid}@test.com", permissions: permissions)
      [user, nil]
    end

    it "checks trashed permission via policy" do
      user, _org = create_user_with_permissions(["posts.trashed"])
      policy = PostPolicy.new(user, Post)
      expect(policy.view_trashed?).to be true
    end

    it "denies trashed without permission" do
      user, _org = create_user_with_permissions(["posts.index"])
      policy = PostPolicy.new(user, Post)
      expect(policy.view_trashed?).to be false
    end

    it "checks restore permission via policy" do
      user, _org = create_user_with_permissions(["posts.restore"])
      policy = PostPolicy.new(user, Post)
      expect(policy.restore?).to be true
    end

    it "denies restore without permission" do
      user, _org = create_user_with_permissions(["posts.update"])
      policy = PostPolicy.new(user, Post)
      expect(policy.restore?).to be false
    end

    it "checks forceDelete permission via policy" do
      user, _org = create_user_with_permissions(["posts.forceDelete"])
      policy = PostPolicy.new(user, Post)
      expect(policy.force_delete?).to be true
    end

    it "denies forceDelete without permission" do
      user, _org = create_user_with_permissions(["posts.destroy"])
      policy = PostPolicy.new(user, Post)
      expect(policy.force_delete?).to be false
    end

    it "wildcard grants all soft delete actions" do
      user, _org = create_user_with_permissions(["*"])
      policy = PostPolicy.new(user, Post)
      expect(policy.view_trashed?).to be true
      expect(policy.restore?).to be true
      expect(policy.force_delete?).to be true
    end

    it "resource wildcard grants soft delete actions" do
      user, _org = create_user_with_permissions(["posts.*"])
      policy = PostPolicy.new(user, Post)
      expect(policy.view_trashed?).to be true
      expect(policy.restore?).to be true
      expect(policy.force_delete?).to be true
    end
  end
end
