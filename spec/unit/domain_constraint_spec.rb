# frozen_string_literal: true

require "spec_helper"
require "rhino/routing/domain_constraint"

RSpec.describe Rhino::Routing::DomainConstraint do
  def request_for(host, path_params = {})
    env = Rack::MockRequest.env_for("/", "HTTP_HOST" => host)
    request = ActionDispatch::Request.new(env)
    request.path_parameters = path_params
    request
  end

  # ------------------------------------------------------------------
  # Pattern compilation
  # ------------------------------------------------------------------

  describe "pattern compilation" do
    it "compiles a literal domain to an anchored, case-insensitive regex" do
      constraint = described_class.new("admin.example.com")
      expect(constraint.regexp).to eq(/\Aadmin\.example\.com\z/i)
    end

    it "escapes regex metacharacters in literal text (dots are literal)" do
      constraint = described_class.new("admin.example.com")
      # The dot must match a literal dot, not any character.
      expect(constraint.matches?(request_for("adminXexampleXcom"))).to be false
      expect(constraint.matches?(request_for("admin.example.com"))).to be true
    end

    it "replaces {name} with a named capture matching a single host label" do
      constraint = described_class.new("{organization}.example.com")
      expect(constraint.regexp).to eq(/\A(?<organization>[^.]+)\.example\.com\z/i)
      expect(constraint.param_names).to eq(["organization"])
    end

    it "supports multiple placeholders" do
      constraint = described_class.new("{tenant}.{region}.example.com")
      expect(constraint.param_names).to eq(%w[tenant region])
      expect(constraint.matches?(request_for("acme.eu.example.com"))).to be true
    end
  end

  # ------------------------------------------------------------------
  # parameterized?
  # ------------------------------------------------------------------

  describe "#parameterized?" do
    it "is false for a literal domain" do
      expect(described_class.new("admin.example.com").parameterized?).to be false
    end

    it "is true for a parameterized domain" do
      expect(described_class.new("{organization}.example.com").parameterized?).to be true
    end
  end

  # ------------------------------------------------------------------
  # matches? — literal
  # ------------------------------------------------------------------

  describe "#matches? with a literal domain" do
    let(:constraint) { described_class.new("admin.example.com") }

    it "matches the exact host" do
      expect(constraint.matches?(request_for("admin.example.com"))).to be true
    end

    it "matches case-insensitively (hosts are case-insensitive)" do
      expect(constraint.matches?(request_for("ADMIN.Example.COM"))).to be true
    end

    it "does not match a different host" do
      expect(constraint.matches?(request_for("app.example.com"))).to be false
    end

    it "does not match a host with an extra leading label" do
      expect(constraint.matches?(request_for("x.admin.example.com"))).to be false
    end

    it "does not match a substring host (anchored)" do
      expect(constraint.matches?(request_for("admin.example.com.evil.com"))).to be false
    end

    it "does not inject path parameters for a literal domain" do
      request = request_for("admin.example.com", {})
      constraint.matches?(request)
      expect(request.path_parameters).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # matches? — parameterized
  # ------------------------------------------------------------------

  describe "#matches? with a parameterized domain" do
    let(:constraint) { described_class.new("{organization}.example.com") }

    it "matches a subdomain host" do
      expect(constraint.matches?(request_for("org-one.example.com"))).to be true
    end

    it "does not match the bare base host (no subdomain label)" do
      expect(constraint.matches?(request_for("example.com"))).to be false
    end

    it "does not match a multi-label subdomain (single label only)" do
      expect(constraint.matches?(request_for("a.b.example.com"))).to be false
    end

    it "does not match a different base domain" do
      expect(constraint.matches?(request_for("org-one.other.com"))).to be false
    end

    it "injects the captured subdomain into path_parameters" do
      request = request_for("org-one.example.com", {})
      constraint.matches?(request)
      expect(request.path_parameters[:organization]).to eq("org-one")
    end

    it "injects each capture for multi-placeholder domains" do
      multi = described_class.new("{tenant}.{region}.example.com")
      request = request_for("acme.eu.example.com", {})
      multi.matches?(request)
      expect(request.path_parameters[:tenant]).to eq("acme")
      expect(request.path_parameters[:region]).to eq("eu")
    end

    it "does not overwrite a path parameter already present on the request" do
      request = request_for("org-one.example.com", { organization: "explicit-from-path" })
      constraint.matches?(request)
      expect(request.path_parameters[:organization]).to eq("explicit-from-path")
    end

    it "does not mutate path_parameters when the host does not match" do
      request = request_for("example.com", {})
      constraint.matches?(request)
      expect(request.path_parameters).to eq({})
    end
  end
end
