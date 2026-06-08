# frozen_string_literal: true

namespace :rhino do
  desc "Install and configure Rhino for your Rails application"
  task install: :environment do
    require "rhino/commands/install_command"
    Rhino::Commands::InstallCommand.new.perform
  end

  desc "Generate Rhino resources (Model, Policy, Scope)"
  task generate: :environment do
    require "rhino/commands/generate_command"
    Rhino::Commands::GenerateCommand.new.perform
  end

  desc "Generate code from YAML blueprint files"
  task blueprint: :environment do
    require "rhino/commands/blueprint_command"
    Rhino::Commands::BlueprintCommand.new.perform
  end

  desc "Export Postman collection for all registered models"
  task export_postman: :environment do
    require "rhino/commands/export_postman_command"
    cmd = Rhino::Commands::ExportPostmanCommand.new
    cmd.perform
  end

  desc "Lift per-user permissions into the org_role_permissions role layer (APPLY=1 to write)"
  task :permissions_migrate, [:apply] => :environment do |_t, args|
    require "rhino/permissions_migrator"
    apply = args[:apply].to_s == "apply" || ENV["APPLY"] == "1"
    result = Rhino::PermissionsMigrator.call(apply: apply)
    result.lines.each { |line| puts line }
    verb = apply ? "Migrated" : "Would migrate"
    summary = "#{verb} #{result.groups_migrated} (org, role) group(s); #{result.rows_reduced} user row(s) reduced to deltas."
    summary += " Skipped #{result.skipped_existing} group(s) with an existing role layer." if result.skipped_existing.positive?
    puts summary
    puts "Dry-run only. Re-run with APPLY=1 to write these changes." if !apply && result.groups_migrated.positive?
  end

  desc "Generate TypeScript type definitions from registered Rhino models"
  task :export_types, [:output] => :environment do |_t, args|
    require "rhino/commands/export_types_command"
    cmd = Rhino::Commands::ExportTypesCommand.new
    cmd.options = { output: args[:output] || ENV["OUTPUT"] }
    cmd.perform
  end
end

namespace :invitation do
  desc "Generate an invitation link for testing"
  task :link, [:email, :organization] => :environment do |_t, args|
    require "rhino/commands/invitation_link_command"
    cmd = Rhino::Commands::InvitationLinkCommand.new
    cmd.email = args[:email]
    cmd.organization_identifier = args[:organization]
    cmd.perform
  end
end
