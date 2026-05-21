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
