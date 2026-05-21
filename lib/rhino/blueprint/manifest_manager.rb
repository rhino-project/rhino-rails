# frozen_string_literal: true

require "json"

module Rhino
  module Blueprint
    # Tracks file hashes and generated files for change detection.
    # Port of rhino-server ManifestManager.php / rhino-adonis-server manifest_manager.ts.
    class ManifestManager
      def initialize(blueprints_dir)
        @manifest_path = File.join(blueprints_dir, ".blueprint-manifest.json")
        @manifest = load_manifest
      end

      # Check if a blueprint file has changed since last generation.
      def has_changed?(filename, current_hash)
        entry = @manifest.dig("files", filename)
        return true unless entry

        entry["content_hash"] != current_hash
      end

      # Record a successful generation.
      def record_generation(filename, content_hash, generated_files)
        @manifest["files"][filename] = {
          "content_hash" => content_hash,
          "generated_files" => generated_files,
          "generated_at" => Time.now.iso8601
        }
        @manifest["generated_at"] = Time.now.iso8601
      end

      # Get the list of generated files for a blueprint.
      def get_generated_files(filename)
        @manifest.dig("files", filename, "generated_files") || []
      end

      # Get all tracked blueprint filenames.
      def get_tracked_files
        @manifest["files"].keys
      end

      # Remove tracking for a blueprint file.
      def remove_tracking(filename)
        @manifest["files"].delete(filename)
      end

      # Save manifest to disk.
      def save
        File.write(@manifest_path, JSON.pretty_generate(@manifest))
      end

      # Load manifest from disk, returning empty structure if missing or corrupted.
      def load_manifest
        return empty_manifest unless File.exist?(@manifest_path)

        begin
          parsed = JSON.parse(File.read(@manifest_path))

          if parsed.is_a?(Hash) && parsed["version"] && parsed["files"]
            parsed
          else
            empty_manifest
          end
        rescue JSON::ParserError
          empty_manifest
        end
      end

      private

      def empty_manifest
        {
          "version" => 1,
          "generated_at" => Time.now.iso8601,
          "files" => {}
        }
      end
    end
  end
end
