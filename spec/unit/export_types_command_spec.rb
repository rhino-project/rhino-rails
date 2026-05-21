# frozen_string_literal: true

require "spec_helper"
require "json"
require "rhino/commands/export_types_command"

RSpec.describe Rhino::Commands::ExportTypesCommand do
  let(:tmp_dir) { Dir.mktmpdir("rhino_types_test") }
  let(:command) { described_class.new }

  before do
    allow(command).to receive(:say)
  end

  after do
    FileUtils.remove_entry(tmp_dir)
  end

  # ------------------------------------------------------------------
  # slug_to_interface_name
  # ------------------------------------------------------------------

  describe "#slug_to_interface_name" do
    it "converts plural slug to singular PascalCase" do
      expect(command.send(:slug_to_interface_name, :posts)).to eq("Post")
    end

    it "converts underscored slug to PascalCase" do
      expect(command.send(:slug_to_interface_name, :blog_categories)).to eq("BlogCategory")
    end

    it "converts hyphenated slug to PascalCase" do
      expect(command.send(:slug_to_interface_name, :"blog-categories")).to eq("BlogCategory")
    end

    it "handles single-word slug" do
      expect(command.send(:slug_to_interface_name, :blogs)).to eq("Blog")
    end
  end

  # ------------------------------------------------------------------
  # map_column_type
  # ------------------------------------------------------------------

  describe "#map_column_type" do
    it "maps integer to integer" do
      expect(command.send(:map_column_type, "integer")).to eq({ type: "integer" })
    end

    it "maps bigint to integer" do
      expect(command.send(:map_column_type, "bigint")).to eq({ type: "integer" })
    end

    it "maps decimal to number" do
      expect(command.send(:map_column_type, "decimal")).to eq({ type: "number" })
    end

    it "maps float to number" do
      expect(command.send(:map_column_type, "float")).to eq({ type: "number" })
    end

    it "maps boolean to boolean" do
      expect(command.send(:map_column_type, "boolean")).to eq({ type: "boolean" })
    end

    it "maps datetime to string with date-time format" do
      expect(command.send(:map_column_type, "datetime")).to eq({ type: "string", format: "date-time" })
    end

    it "maps date to string with date-time format" do
      expect(command.send(:map_column_type, "date")).to eq({ type: "string", format: "date-time" })
    end

    it "maps timestamp to string with date-time format" do
      expect(command.send(:map_column_type, "timestamp")).to eq({ type: "string", format: "date-time" })
    end

    it "maps json to object" do
      expect(command.send(:map_column_type, "json")).to eq({ type: "object" })
    end

    it "maps jsonb to object" do
      expect(command.send(:map_column_type, "jsonb")).to eq({ type: "object" })
    end

    it "maps string to string" do
      expect(command.send(:map_column_type, "string")).to eq({ type: "string" })
    end

    it "maps text to string" do
      expect(command.send(:map_column_type, "text")).to eq({ type: "string" })
    end

    it "maps unknown types to string" do
      expect(command.send(:map_column_type, "binary")).to eq({ type: "string" })
    end
  end

  # ------------------------------------------------------------------
  # introspect_columns
  # ------------------------------------------------------------------

  describe "#introspect_columns" do
    it "returns properties for a model with columns" do
      properties = command.send(:introspect_columns, Post)

      expect(properties).to be_a(Hash)
      expect(properties).not_to be_empty
      expect(properties).to have_key("id")
      expect(properties).to have_key("title")
      expect(properties).to have_key("content")
      expect(properties).to have_key("is_published")
      expect(properties).to have_key("created_at")
    end

    it "maps integer columns correctly" do
      properties = command.send(:introspect_columns, Post)

      expect(properties["id"][:type]).to eq("integer")
    end

    it "maps string columns correctly" do
      properties = command.send(:introspect_columns, Post)

      expect(properties["title"][:type]).to eq("string")
    end

    it "maps text columns correctly" do
      properties = command.send(:introspect_columns, Post)

      expect(properties["content"][:type]).to eq("string")
    end

    it "maps boolean columns correctly" do
      properties = command.send(:introspect_columns, Post)

      expect(properties["is_published"][:type]).to eq("boolean")
    end

    it "maps datetime columns correctly" do
      properties = command.send(:introspect_columns, Post)

      expect(properties["created_at"][:type]).to eq("string")
      expect(properties["created_at"][:format]).to eq("date-time")
    end

    it "marks nullable columns" do
      properties = command.send(:introspect_columns, Post)

      # content is nullable (no null: false)
      expect(properties["content"][:nullable]).to be true
    end

    it "does not mark non-nullable columns" do
      properties = command.send(:introspect_columns, Post)

      # title has null: false
      expect(properties["title"][:nullable]).to be_falsey
    end

    it "returns empty hash for non-AR class" do
      plain_class = Class.new
      properties = command.send(:introspect_columns, plain_class)

      expect(properties).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # build_openapi_spec
  # ------------------------------------------------------------------

  describe "#build_openapi_spec" do
    it "builds a valid OpenAPI 3.0.3 spec" do
      schemas = {
        "Post" => {
          type: "object",
          properties: {
            "id" => { type: "integer" },
            "title" => { type: "string" }
          }
        }
      }

      spec = command.send(:build_openapi_spec, schemas)

      expect(spec[:openapi]).to eq("3.0.3")
      expect(spec[:info][:version]).to eq("1.0.0")
      expect(spec[:paths]).to eq({})
      expect(spec[:components][:schemas]).to eq(schemas)
    end

    it "includes app name in spec title" do
      schemas = { "Post" => { type: "object", properties: {} } }
      spec = command.send(:build_openapi_spec, schemas)

      expect(spec[:info][:title]).to include("Models")
    end
  end

  # ------------------------------------------------------------------
  # resolve_output_paths
  # ------------------------------------------------------------------

  describe "#resolve_output_paths" do
    it "returns explicit output path when set" do
      command.options = { output: "/tmp/types.d.ts" }

      paths = command.send(:resolve_output_paths)

      expect(paths).to eq(["/tmp/types.d.ts"])
    end

    it "returns empty array when no paths configured" do
      command.options = { output: nil }
      stub_const("ENV", ENV.to_h.merge(
        "RHINO_CLIENT_PATH" => nil,
        "RHINO_MOBILE_PATH" => nil
      ))

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      paths = command.send(:resolve_output_paths)

      expect(paths).to be_empty
    end

    it "uses RHINO_CLIENT_PATH env var" do
      command.options = { output: nil }
      stub_const("ENV", ENV.to_h.merge(
        "RHINO_CLIENT_PATH" => "/tmp/client",
        "RHINO_MOBILE_PATH" => nil
      ))

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      paths = command.send(:resolve_output_paths)

      expect(paths).to eq(["/tmp/client/src/types/rhino.d.ts"])
    end

    it "uses RHINO_MOBILE_PATH env var" do
      command.options = { output: nil }
      stub_const("ENV", ENV.to_h.merge(
        "RHINO_CLIENT_PATH" => nil,
        "RHINO_MOBILE_PATH" => "/tmp/mobile"
      ))

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      paths = command.send(:resolve_output_paths)

      expect(paths).to eq(["/tmp/mobile/src/types/rhino.d.ts"])
    end

    it "returns both paths when both env vars are set" do
      command.options = { output: nil }
      stub_const("ENV", ENV.to_h.merge(
        "RHINO_CLIENT_PATH" => "/tmp/client",
        "RHINO_MOBILE_PATH" => "/tmp/mobile"
      ))

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      paths = command.send(:resolve_output_paths)

      expect(paths).to eq([
        "/tmp/client/src/types/rhino.d.ts",
        "/tmp/mobile/src/types/rhino.d.ts"
      ])
    end

    it "uses config client_path over env var" do
      command.options = { output: nil }
      stub_const("ENV", ENV.to_h.merge(
        "RHINO_CLIENT_PATH" => nil,
        "RHINO_MOBILE_PATH" => nil
      ))

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
        c.client_path = "/configured/client"
      end

      paths = command.send(:resolve_output_paths)

      expect(paths).to eq(["/configured/client/src/types/rhino.d.ts"])
    end
  end

  # ------------------------------------------------------------------
  # perform — full integration (with mocked npx)
  # ------------------------------------------------------------------

  describe "#perform" do
    it "returns true when no models are registered" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.route_group :default, prefix: "", models: :all
      end

      result = command.perform

      expect(result).to be true
      expect(command).to have_received(:say).with(
        "No models registered in Rhino configuration.", :yellow
      )
    end

    it "returns false when no output paths are configured" do
      command.options = { output: nil }
      stub_const("ENV", ENV.to_h.merge(
        "RHINO_CLIENT_PATH" => nil,
        "RHINO_MOBILE_PATH" => nil
      ))

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      result = command.perform

      expect(result).to be false
    end

    it "warns about non-existent model classes" do
      output_path = File.join(tmp_dir, "types.d.ts")
      command.options = { output: output_path }

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :ghosts, "NonExistentModel"
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      allow(command).to receive(:run_openapi_typescript).and_return(0)
      command.perform

      expect(command).to have_received(:say).with(
        "Model class does not exist: NonExistentModel", :red
      )
    end

    it "generates OpenAPI spec and calls npx openapi-typescript" do
      output_path = File.join(tmp_dir, "types.d.ts")
      command.options = { output: output_path }

      allow(command).to receive(:run_openapi_typescript) do |input_file, out_file|
        # Verify the temp JSON file contains valid OpenAPI spec
        spec = JSON.parse(File.read(input_file))
        expect(spec["openapi"]).to eq("3.0.3")
        expect(spec["components"]["schemas"]).to have_key("Post")
        expect(spec["components"]["schemas"]).to have_key("Blog")

        # Verify Post schema has expected properties
        post_props = spec["components"]["schemas"]["Post"]["properties"]
        expect(post_props["id"]["type"]).to eq("integer")
        expect(post_props["title"]["type"]).to eq("string")
        expect(post_props["content"]["type"]).to eq("string")
        expect(post_props["is_published"]["type"]).to eq("boolean")

        # Simulate success by writing a dummy .d.ts file
        File.write(out_file, "// generated types\n")
        0
      end

      result = command.perform

      expect(result).to be true
      expect(command).to have_received(:say).with(
        "Generated TypeScript types at: #{output_path}", :green
      )
    end

    it "returns false when npx openapi-typescript fails" do
      output_path = File.join(tmp_dir, "types.d.ts")
      command.options = { output: output_path }

      allow(command).to receive(:run_openapi_typescript).and_return(1)

      result = command.perform

      expect(result).to be false
    end

    it "creates output directory if it does not exist" do
      nested_path = File.join(tmp_dir, "deep", "nested", "dir", "types.d.ts")
      command.options = { output: nested_path }

      allow(command).to receive(:run_openapi_typescript) do |_input, out_file|
        File.write(out_file, "// types\n")
        0
      end

      command.perform

      expect(Dir.exist?(File.dirname(nested_path))).to be true
    end

    it "generates correct schema for Post model" do
      output_path = File.join(tmp_dir, "types.d.ts")
      command.options = { output: output_path }

      captured_spec = nil
      allow(command).to receive(:run_openapi_typescript) do |input_file, out_file|
        captured_spec = JSON.parse(File.read(input_file))
        File.write(out_file, "// types\n")
        0
      end

      command.perform

      post_schema = captured_spec["components"]["schemas"]["Post"]
      expect(post_schema["type"]).to eq("object")

      props = post_schema["properties"]
      # id is integer, not nullable
      expect(props["id"]["type"]).to eq("integer")
      expect(props["id"]["nullable"]).to be_falsey

      # title is string, not nullable (null: false in migration)
      expect(props["title"]["type"]).to eq("string")
      expect(props["title"]["nullable"]).to be_falsey

      # content is text -> string, nullable
      expect(props["content"]["type"]).to eq("string")
      expect(props["content"]["nullable"]).to be true

      # is_published is boolean, nullable
      expect(props["is_published"]["type"]).to eq("boolean")

      # created_at is datetime -> string with format
      expect(props["created_at"]["type"]).to eq("string")
      expect(props["created_at"]["format"]).to eq("date-time")
    end

    it "generates correct schema for Blog model" do
      output_path = File.join(tmp_dir, "types.d.ts")
      command.options = { output: output_path }

      captured_spec = nil
      allow(command).to receive(:run_openapi_typescript) do |input_file, out_file|
        captured_spec = JSON.parse(File.read(input_file))
        File.write(out_file, "// types\n")
        0
      end

      command.perform

      blog_schema = captured_spec["components"]["schemas"]["Blog"]
      expect(blog_schema["type"]).to eq("object")

      props = blog_schema["properties"]
      expect(props["id"]["type"]).to eq("integer")
      expect(props["title"]["type"]).to eq("string")
      expect(props["organization_id"]["type"]).to eq("integer")
    end

    it "writes to multiple output paths" do
      client_path = File.join(tmp_dir, "client", "types.d.ts")
      mobile_path = File.join(tmp_dir, "mobile", "types.d.ts")

      command.options = { output: nil }
      stub_const("ENV", ENV.to_h.merge(
        "RHINO_CLIENT_PATH" => nil,
        "RHINO_MOBILE_PATH" => nil
      ))

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
        c.client_path = File.join(tmp_dir, "client_proj")
        c.mobile_path = File.join(tmp_dir, "mobile_proj")
      end

      allow(command).to receive(:run_openapi_typescript) do |_input, out_file|
        File.write(out_file, "// types\n")
        0
      end

      result = command.perform

      expect(result).to be true
      expect(command).to have_received(:run_openapi_typescript).twice
    end

    it "cleans up temp file even on failure" do
      output_path = File.join(tmp_dir, "types.d.ts")
      command.options = { output: output_path }

      # Track temp files created before this test
      before_temp_files = Dir.glob(File.join(Dir.tmpdir, "rhino_openapi_*"))

      allow(command).to receive(:run_openapi_typescript).and_return(1)

      command.perform

      # Verify no new temp files are left behind
      after_temp_files = Dir.glob(File.join(Dir.tmpdir, "rhino_openapi_*"))
      new_temp_files = after_temp_files - before_temp_files
      expect(new_temp_files).to be_empty
    end
  end
end
