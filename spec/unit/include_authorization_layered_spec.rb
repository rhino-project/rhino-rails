# frozen_string_literal: true

require "spec_helper"
require "request_store"

# Fixture: relation name 'assignee' deliberately differs from the related model
# (User), to prove include-auth gates on the related MODEL, not the relation name.
class IncludeAssigneeTask < ActiveRecord::Base
  self.table_name = "include_assignee_tasks"
  belongs_to :assignee, class_name: "User", optional: true
end

# Layered permissions on a DIFFERENTLY-NAMED relation include.
#
# Mirrors ResourcesController#authorize_includes: an include is authorized
# against the RELATED MODEL's policy/slug (resolved via reflect_on_association),
# NOT the relation name. So `assignee` -> User authorizes `users.*`, governed by
# the layered resolver: effective = (org_role_permissions ∪ granted) − denied,
# deny always wins.
RSpec.describe "Include authorization (layered, differently-named relation)" do
  before(:all) do
    unless ActiveRecord::Base.connection.table_exists?(:include_assignee_tasks)
      ActiveRecord::Base.connection.create_table :include_assignee_tasks do |t|
        t.references :assignee
        t.string :title
      end
    end
  end

  before(:each) do
    # Fresh policy class each test so ResourcePolicy's slug cache never leaks.
    stub_const("UserPolicy", Class.new(Rhino::ResourcePolicy))
  end

  after(:each) do
    RequestStore.store[:rhino_organization] = nil
  end

  # Exactly what ResourcesController#authorize_includes does for `assignee`:
  # resolve the association's related class, find its policy, ask index?.
  def include_authorized?(user)
    related = IncludeAssigneeTask.reflect_on_association(:assignee).klass
    policy_class = "#{related.name}Policy".safe_constantize || Rhino::ResourcePolicy
    policy_class.new(user, related).index?
  end

  def setup_user(role_layer:, granted: [], denied: [], register_users: true)
    Rhino.config.model(:users, "User") if register_users

    org = Organization.create!(name: "O", slug: "o-#{SecureRandom.hex(4)}")
    role = Role.create!(name: "R", slug: "r-#{SecureRandom.hex(4)}")
    user = User.create!(name: "U", email: "u-#{SecureRandom.hex(4)}@example.com")
    UserRole.create!(
      user: user, organization: org, role: role,
      permissions: [], granted_permissions: granted, denied_permissions: denied
    )
    OrgRolePermission.create!(organization: org, role: role, permissions: role_layer)
    RequestStore.store[:rhino_organization] = org
    user
  end

  it "resolves the include against the related model, not the relation name" do
    expect(IncludeAssigneeTask.reflect_on_association(:assignee).klass).to eq(User)
  end

  it "allows the include when the role layer grants the related slug" do
    user = setup_user(role_layer: ["users.*"])
    expect(include_authorized?(user)).to be true
  end

  it "DENIES the include when the user is explicitly denied (deny wins over role '*')" do
    user = setup_user(role_layer: ["*"], denied: ["users.*"])
    expect(include_authorized?(user)).to be false
  end

  it "DENIES the include for an exact deny under a role wildcard" do
    user = setup_user(role_layer: ["*"], denied: ["users.index"])
    expect(include_authorized?(user)).to be false
  end

  it "default-denies when no slug permission exists anywhere" do
    user = setup_user(role_layer: ["tasks.*"])
    expect(include_authorized?(user)).to be false
  end

  it "allows via a per-user grant of the related slug" do
    user = setup_user(role_layer: [], granted: ["users.index"])
    expect(include_authorized?(user)).to be true
  end

  it "hard-denies the include when the related model is NOT a registered resource" do
    # No slug for User in Rhino.config → resolve_resource_slug is nil → deny,
    # even though the role layer grants '*'. This is the intended hard-deny for
    # includes that resolve to a model the lib doesn't recognize.
    user = setup_user(role_layer: ["*"], register_users: false)
    expect(include_authorized?(user)).to be false
  end
end
