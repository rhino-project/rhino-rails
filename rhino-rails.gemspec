# frozen_string_literal: true

require_relative "lib/rhino/version"

Gem::Specification.new do |spec|
  spec.name = "rhino-rails"
  spec.version = Rhino::VERSION
  spec.authors = ["Bruno Cipolla"]
  spec.email = ["bruno@codalio.com"]

  spec.summary = "Automatic REST API generation for Rails models"
  spec.description = "Rhino automatically generates complete REST APIs from ActiveRecord models with filtering, sorting, search, pagination, role-based authorization, multi-tenancy, audit trail, and more."
  spec.homepage = "https://github.com/rhino-project/rhino-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.files = Dir["lib/**/*", "config/**/*", "MIT-LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "pundit", "~> 2.3"
  spec.add_dependency "pagy", "~> 9.0"
  spec.add_dependency "discard", "~> 1.3"
  spec.add_dependency "bcrypt", "~> 3.1"
  spec.add_dependency "tty-prompt", "~> 0.23"
  spec.add_dependency "request_store", "~> 1.5"

  spec.add_development_dependency "rspec-rails", "~> 7.0"
  spec.add_development_dependency "factory_bot_rails", "~> 6.4"
  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "combustion", "~> 1.4"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
