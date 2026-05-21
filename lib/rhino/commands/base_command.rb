# frozen_string_literal: true

require "tty-prompt"

module Rhino
  module Commands
    # Lightweight base for Rhino CLI commands.
    # Uses tty-prompt for interactive, navigable terminal UI.
    class BaseCommand
      def initialize
        @prompt = TTY::Prompt.new(
          active_color: :cyan,
          help_color: :dim
        )
      end

      private

      def say(message = "", color = nil)
        if color
          message = @prompt.decorate(message, color)
        end
        puts message
      end

      def ask(message, **options)
        @prompt.ask(message, **options)
      end

      def yes?(message)
        @prompt.yes?(message)
      end

      def select(label, choices = nil, **options, &block)
        if block
          @prompt.select(label, **options, &block)
        else
          @prompt.select(label, choices, **options)
        end
      end

      def multi_select(label, choices = nil, **options, &block)
        if block
          @prompt.multi_select(label, **options, &block)
        else
          @prompt.multi_select(label, choices, **options)
        end
      end

      def task(description)
        print "  → #{@prompt.decorate(description + '...', :cyan)}"
        yield
        puts "\r  ✓ #{@prompt.decorate(description, :green)}    "
      end
    end
  end
end
