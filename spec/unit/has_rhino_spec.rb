# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::HasRhino do
  describe "DSL methods" do
    it "sets rhino_per_page" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"

        rhino_per_page 50
      end

      expect(klass.rhino_per_page_count).to eq(50)
    end

    it "sets rhino_pagination_enabled" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"

        rhino_pagination_enabled true
      end

      expect(klass.pagination_enabled).to be true
    end

    it "sets rhino_middleware" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"

        rhino_middleware "throttle:60,1", "auth"
      end

      expect(klass.rhino_model_middleware).to eq(["throttle:60,1", "auth"])
    end

    it "sets rhino_middleware_actions" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"

        rhino_middleware_actions store: ["verified"], update: ["verified"]
      end

      expect(klass.rhino_middleware_actions_map).to eq("store" => ["verified"], "update" => ["verified"])
    end

    it "sets rhino_except_actions" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"

        rhino_except_actions :destroy, :force_delete
      end

      expect(klass.rhino_except_actions_list).to eq(["destroy", "force_delete"])
    end

    it "sets rhino_route_key and stores it as a string" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "jobs"

        rhino_route_key :hash_id
      end

      expect(klass.rhino_route_key_column).to eq("hash_id")
    end

    it "defaults rhino_route_key_column to nil" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"
      end

      expect(klass.rhino_route_key_column).to be_nil
    end
  end

  describe ".rhino_resolved_route_key" do
    it "returns the primary key when nothing is configured" do
      expect(Post.rhino_resolved_route_key).to eq("id")
    end

    it "returns the model-level route key" do
      expect(Job.rhino_resolved_route_key).to eq("hash_id")
    end

    it "prefers the model-level route key over the global config" do
      Rhino.config.route_key = "title"
      expect(Job.rhino_resolved_route_key).to eq("hash_id")
    end

    it "falls back to the global config when the model is silent" do
      Rhino.config.route_key = "hash_id"
      expect(Task.rhino_resolved_route_key).to eq("hash_id")
    end

    it "raises ArgumentError when the model-level column does not exist" do
      klass = Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        self.table_name = "posts"

        rhino_route_key :nonexistent_column
      end

      expect { klass.rhino_resolved_route_key }
        .to raise_error(ArgumentError, /nonexistent_column/)
    end

    it "raises ArgumentError when the global column does not exist on the model" do
      Rhino.config.route_key = "hash_id"
      expect { Blog.rhino_resolved_route_key }
        .to raise_error(ArgumentError, /hash_id/)
    end
  end

  describe ".uses_soft_deletes?" do
    it "returns true when model has discarded_at column" do
      expect(Post.uses_soft_deletes?).to be true
    end

    it "returns false when model lacks soft delete columns" do
      expect(Blog.uses_soft_deletes?).to be false
    end
  end
end
