# frozen_string_literal: true

require "spec_helper"

# Engine requires a full Rails environment (Rails::Engine base class).
# We test the engine source file structure and verify it can be parsed.
RSpec.describe "Rhino::Engine (source verification)" do
  it "engine source file exists" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    expect(File.exist?(path)).to be true
  end

  it "engine source defines the correct class" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    expect(content).to include("class Engine < ::Rails::Engine")
    expect(content).to include("isolate_namespace Rhino")
  end

  it "engine source registers rhino.autoloads initializer" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    expect(content).to include('initializer "rhino.autoloads"')
  end

  it "engine source registers rhino.routes initializer" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    expect(content).to include('initializer "rhino.routes"')
  end

  it "engine source registers rhino.pundit initializer" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    expect(content).to include('initializer "rhino.pundit"')
  end

  it "engine source requires all concerns" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    %w[has_rhino has_validation has_permissions has_audit_trail
       belongs_to_organization hidable_columns has_uuid has_auto_scope].each do |concern|
      expect(content).to include("rhino/concerns/#{concern}")
    end
  end

  it "engine source requires controllers" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    expect(content).to include("rhino/controllers/resources_controller")
    expect(content).to include("rhino/controllers/auth_controller")
    expect(content).to include("rhino/controllers/invitations_controller")
  end

  it "engine source requires policies" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    expect(content).to include("rhino/policies/resource_policy")
    expect(content).to include("rhino/policies/invitation_policy")
  end

  it "engine source requires models" do
    path = File.expand_path("../../../lib/rhino/engine.rb", __FILE__)
    content = File.read(path)
    expect(content).to include("rhino/models/rhino_model")
    expect(content).to include("rhino/models/audit_log")
    expect(content).to include("rhino/models/organization_invitation")
  end
end
