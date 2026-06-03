# frozen_string_literal: true

require "spec_helper"
require "rhino/routes"

# Route groups that would silently shadow each other must raise at boot
# (route-draw) time. A group's routing identity is (host-set, prefix) per model;
# two groups conflict when their host-sets intersect, they share a prefix, and
# their models overlap. Without a distinguishing domain, overlapping groups need
# distinct prefixes.
RSpec.describe "Route group conflict validation" do
  def configure
    Rhino.reset_configuration!
    Rhino.configure do |c|
      c.model :posts, "Post"
      c.model :blogs, "Blog"
      yield c
    end
  end

  # Drawing the routes runs the validator (mirrors boot).
  def build_routes
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { Rhino::Routes.draw(self) }
    routes
  end

  def validate!
    Rhino::Routing::RouteGroupValidator.validate(Rhino.config)
  end

  # ==================================================================
  # Cases that MUST raise
  # ==================================================================

  describe "conflicting configurations raise RouteGroupConflictError" do
    it "two root groups without a domain" do
      configure do |c|
        c.route_group :a, prefix: "", models: :all
        c.route_group :b, prefix: "", models: :all
      end

      expect { build_routes }.to raise_error(Rhino::RouteGroupConflictError)
    end

    it "wildcard models overlapping a subset at root" do
      configure do |c|
        c.route_group :a, prefix: "", models: :all
        c.route_group :b, prefix: "", models: [:posts]
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError)
    end

    it "same non-empty prefix without a domain" do
      configure do |c|
        c.route_group :a, prefix: "admin", models: :all
        c.route_group :b, prefix: "admin", models: :all
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError)
    end

    it "same prefix and same literal domain" do
      configure do |c|
        c.route_group :a, prefix: "", domain: "app.example.com", models: :all
        c.route_group :b, prefix: "", domain: "app.example.com", models: :all
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError)
    end

    it "same prefix and same parameterized domain" do
      configure do |c|
        c.route_group :a, prefix: "", domain: "{organization}.example.com", models: :all
        c.route_group :b, prefix: "", domain: "{organization}.example.com", models: :all
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError)
    end

    it "a no-domain catch-all group conflicts with a domained group (wildcard host)" do
      configure do |c|
        c.route_group :catch_all, prefix: "", models: :all
        c.route_group :admin, prefix: "", domain: "admin.example.com", models: :all
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError)
    end

    it "a blank domain does not rescue a root collision" do
      configure do |c|
        c.route_group :a, prefix: "", domain: "", models: :all
        c.route_group :b, prefix: "", models: :all
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError)
    end

    it "an omitted prefix collides with an explicit root prefix" do
      configure do |c|
        c.route_group :a, models: :all
        c.route_group :b, prefix: "", models: :all
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError)
    end
  end

  describe "the error names the offending pair and details" do
    it "names only the conflicting pair among several groups" do
      configure do |c|
        c.route_group :driver, prefix: "driver", models: :all
        c.route_group :a, prefix: "", models: [:posts]
        c.route_group :admin, prefix: "admin", models: :all
        c.route_group :b, prefix: "", models: [:posts]
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError) do |error|
        expect(error.message).to include(":a", ":b")
        expect(error.message).not_to include(":driver")
        expect(error.message).not_to include(":admin")
      end
    end

    it "names the shared prefix and overlapping models" do
      configure do |c|
        c.route_group :first, prefix: "shared", models: [:posts]
        c.route_group :second, prefix: "shared", models: [:posts]
      end

      expect { validate! }.to raise_error(Rhino::RouteGroupConflictError) do |error|
        expect(error.message).to include(":first", ":second", "shared", "posts")
      end
    end
  end

  # ==================================================================
  # Cases that must NOT raise
  # ==================================================================

  describe "valid configurations do not raise" do
    it "disjoint models at root without a domain" do
      configure do |c|
        c.route_group :a, prefix: "", models: [:posts]
        c.route_group :b, prefix: "", models: [:blogs]
      end

      expect { validate! }.not_to raise_error
      expect { build_routes }.not_to raise_error
    end

    it "same prefix with distinct literal domains" do
      configure do |c|
        c.route_group :us, prefix: "", domain: "us.example.com", models: :all
        c.route_group :eu, prefix: "", domain: "eu.example.com", models: :all
      end

      expect { validate! }.not_to raise_error
    end

    it "distinct parameterized domains at the same prefix" do
      configure do |c|
        c.route_group :a, prefix: "", domain: "{organization}.a.example.com", models: :all
        c.route_group :b, prefix: "", domain: "{organization}.b.example.com", models: :all
      end

      expect { validate! }.not_to raise_error
    end

    it "the same domain with different prefixes" do
      configure do |c|
        c.route_group :a, prefix: "v1", domain: "api.example.com", models: :all
        c.route_group :b, prefix: "v2", domain: "api.example.com", models: :all
      end

      expect { validate! }.not_to raise_error
    end

    it "different prefixes without domains" do
      configure do |c|
        c.route_group :driver, prefix: "driver", models: :all
        c.route_group :admin, prefix: "admin", models: :all
      end

      expect { validate! }.not_to raise_error
    end

    it "a single root group without a domain" do
      configure do |c|
        c.route_group :default, prefix: "", models: :all
      end

      expect { validate! }.not_to raise_error
    end

    it "a single group with a domain and a root (empty) prefix" do
      # The headline requirement: with a subdomain, the prefix is not required.
      configure do |c|
        c.route_group :tenant, prefix: "", domain: "{organization}.example.com", models: :all
      end

      expect { validate! }.not_to raise_error
      expect { build_routes }.not_to raise_error
    end

    it "the tenant and public reserved groups with distinct prefixes" do
      configure do |c|
        c.route_group :tenant, prefix: ":organization", models: :all
        c.route_group :public, prefix: "public", models: [:posts]
      end

      expect { validate! }.not_to raise_error
    end

    it "no route groups configured" do
      Rhino.reset_configuration!
      Rhino.configure { |c| c.model :posts, "Post" }
      Rhino.config.route_groups.clear

      expect { validate! }.not_to raise_error
    end
  end
end
