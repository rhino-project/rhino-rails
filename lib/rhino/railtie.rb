# frozen_string_literal: true

module Rhino
  class Railtie < ::Rails::Railtie
    railtie_name :rhino

    rake_tasks do
      load File.expand_path("tasks/rhino.rake", __dir__)
    end
  end
end
