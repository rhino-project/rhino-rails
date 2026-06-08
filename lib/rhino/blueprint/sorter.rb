# frozen_string_literal: true

module Rhino
  module Blueprint
    # Orders blueprints so that a referenced model's table is created before any
    # model whose migration adds a foreign key to it (parents before children).
    #
    # Foreign keys are taken from +foreignId+ columns that carry a +foreign_model+
    # mapping to another model in the same generation set. References that impose
    # no ordering are ignored:
    #   - self-references (a model's FK to its own table — one migration),
    #   - references to models NOT in this set (e.g. Organization/User, whose
    #     tables are created by +rhino:install+, not the blueprint run).
    #
    # Uses Kahn's algorithm with a stable tie-break: among models with no
    # remaining unmet dependency, the one earliest in the input order wins. The
    # input is already alphabetical (by file name), so the output stays
    # alphabetical wherever relationships don't force a reorder.
    #
    # A circular FK dependency (A -> B -> A) has no linear migration order. Such
    # models are emitted in a deterministic best-effort order and reported via
    # {#cycles} so the caller can warn (one side should be a nullable/deferred FK).
    class Sorter
      # Model names involved in a circular foreign-key dependency during the last
      # {#sort} (empty when the dependency graph is acyclic).
      attr_reader :cycles

      def initialize
        @cycles = []
      end

      # Re-order blueprints into a valid migration sequence (parents first).
      #
      # @param blueprints [Array<Hash>] normalized blueprints (each with a
      #   +:model+ name and +:columns+).
      # @return [Array<Hash>] the blueprints, re-ordered.
      def sort(blueprints)
        @cycles = []
        return blueprints.dup if blueprints.length < 2

        by_model = {}
        blueprints.each do |bp|
          model = bp[:model]
          by_model[model] ||= bp if model
        end

        dependents = {}
        indegree = {}
        by_model.each_key do |m|
          dependents[m] = []
          indegree[m] = 0
        end

        by_model.each do |model, bp|
          seen = {}
          dependency_models(bp).each do |ref|
            next if ref == model || !by_model.key?(ref) || seen[ref]

            seen[ref] = true
            dependents[ref] << model
            indegree[model] += 1
          end
        end

        input_order = by_model.keys

        # Record the models that actually participate in a cycle (reachable from
        # themselves), in input order, so the caller can warn about the full cycle.
        input_order.each do |model|
          @cycles << model if reachable_from_self?(model, dependents)
        end

        ordered = []
        resolved = {}
        while ordered.length < by_model.length
          # Earliest-input model with all dependencies already emitted...
          pick = input_order.find { |m| !resolved[m] && indegree[m].zero? }
          # ...or, when a cycle blocks the graph, the earliest unresolved model
          # (deterministic cycle-break; the cycle itself is reported via #cycles).
          pick ||= input_order.find { |m| !resolved[m] }

          ordered << by_model[pick]
          resolved[pick] = true
          dependents[pick].each { |child| indegree[child] -= 1 }
        end

        ordered
      end

      private

      # Whether +start+ can reach itself by following dependency edges — i.e. it
      # participates in a circular foreign-key dependency. +adj+ maps a model to
      # the models that reference it (its dependents).
      def reachable_from_self?(start, adj)
        stack = (adj[start] || []).dup
        visited = {}
        until stack.empty?
          node = stack.pop
          return true if node == start
          next if visited[node]

          visited[node] = true
          (adj[node] || []).each { |n| stack << n }
        end
        false
      end

      # The model names this blueprint's migration adds foreign keys to, taken
      # from its +foreignId+ columns that carry a +foreign_model+.
      def dependency_models(blueprint)
        (blueprint[:columns] || [])
          .select { |c| c[:type] == "foreignId" && c[:foreign_model] }
          .map { |c| c[:foreign_model] }
      end
    end
  end
end
