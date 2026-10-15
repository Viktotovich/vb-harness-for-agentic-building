# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../model/tokens"
require_relative "../repo/paths"
require_relative "../untrusted"

module Harness
  module Task
    # sections: prompt-ready text blocks, each already fenced; tokens: their estimate; omitted: what did not fit.
    Bundle = Data.define(:sections, :tokens, :omitted)

    # Context bundle for the implementer and fixer (DESIGN.md 7), filled in priority order:
    # 1. the task text; 2. the files it modifies or creates, in full, then the files it reads, in full or as a
    # signature; 3. diagnostics (fix rounds); 4. signatures of the task files' direct imports and importers,
    # then their summaries; 6. completed tasks. Docs passages (5) arrive with the review port (M6).
    module Gather
      MAX_SUMMARIES = 6

      # @param task [Plan::Task]
      # @param root [String] worktree root
      # @param budget [Integer] tokens available for the task text and the bundle
      # @param protected [Array<String>] protectedPaths: never read into a prompt
      # @param task_text [String] the fenced task description (priority 1), counted against the budget
      # @param reserved [Array<String>] text the prompt sends anyway (diagnostics and the diff in a fix round),
      #   counted before anything optional
      # @param done [Array<String>] one-line summaries of completed tasks (priority 6)
      # @param map [Repo::Map, nil] the context map, for signatures and summaries (priority 4)
      # @param summarize [#call, nil] (path, content) -> one sentence; nil uses cached summaries only
      # @return [Bundle]
      # @raise [TaskTooLargeError] when the task and its modified files do not fit
      def self.build(task:, root:, budget:, protected:, task_text:, reserved: [], done: [], map: nil, summarize: nil)
        required = (task.files.modify + task.files.create).uniq.map { |rel| file_section(root, rel, protected) }
        used = Model::Tokens.estimate(task_text) + required.sum { |s| Model::Tokens.estimate(s) }
        if used > budget
          raise TaskTooLargeError, "split #{task.id}: its files need ~#{used} tokens, the budget is #{budget}"
        end

        packer = Packer.new(budget, used + reserved.sum { |r| Model::Tokens.estimate(r) }, required)
        own = (task.files.modify + task.files.create + task.files.read).uniq
        task.files.read.each do |rel|
          signature = map&.signature(rel)
          next if packer.add(rel, file_section(root, rel, protected), fallback: !signature.nil?) || signature.nil?

          packer.add(rel, "Signature of #{rel} (the full file did not fit):\n#{Untrusted.fence(signature)}")
        end
        if map
          related = own.flat_map { |rel| map.related(rel, depth: 1) }.uniq - own
          related.each { |rel| packer.add("signature of #{rel}", "Signature of #{rel}:\n#{Untrusted.fence(map.signature(rel))}") }
          summaries(map, related, summarize, packer)
        end
        packer.add("completed tasks", "Completed tasks:\n#{Untrusted.fence(done.join("\n"))}") unless done.empty?
        packer.bundle
      end

      # Tokens left for the task and its context: the role's context minus its system prompt, the reply
      # schema and the reserved output (DESIGN.md 7).
      # @param client [Model::Client]
      # @param config [Config]
      # @param role [Symbol]
      # @param system [String] the system prompt the call will use
      # @param schema [Hash, nil]
      # @return [Integer]
      def self.budget(client:, config:, role:, system:, schema:)
        caps = client.capabilities(role)
        caps.context_tokens - Model::Tokens.estimate(system) - Model::Tokens.estimate(schema ? JSON.generate(schema) : "") -
          config.profile_for(role).max_output_tokens - Model::Tokens::MESSAGE_OVERHEAD * 2
      end

      # Adds sections in priority order until one does not fit; that one and every later one are omitted, so
      # the lowest priorities are trimmed first.
      class Packer
        # @param budget [Integer]
        # @param used [Integer]
        # @param sections [Array<String>]
        def initialize(budget, used, sections)
          @budget = budget
          @used = used
          @sections = sections.dup
          @omitted = []
          @full = false
        end

        # @param name [String]
        # @param text [String]
        # @param fallback [Boolean] the caller has a smaller form to try next: a miss does not end the packing
        # @return [Boolean] whether it fit
        def add(name, text, fallback: false)
          cost = Model::Tokens.estimate(text)
          if @full || @used + cost > @budget
            return false if fallback && !@full

            @full = true
            @omitted << name
            return false
          end
          @sections << text
          @used += cost
          true
        end

        # Leave a section out without building it; packing ends here.
        # @param name [String]
        # @return [void]
        def omit(name)
          @full = true
          @omitted << name
        end

        # @return [Boolean] whether a section was already left out
        def full? = @full

        # @return [Bundle]
        def bundle = Bundle.new(sections: @sections.freeze, tokens: @used, omitted: @omitted.uniq.freeze)
      end

      # @return [void]
      def self.summaries(map, related, summarize, packer)
        lines = []
        related.first(MAX_SUMMARIES).each do |rel|
          return packer.omit("summaries") if packer.full?

          text = summarize ? map.summary(rel) { |p, content| summarize.call(p, content) } : map.summary(rel)
          lines << "#{rel}: #{text}" if text
        end
        packer.add("summaries", "Summaries of related files:\n#{Untrusted.fence(lines.join("\n"))}") unless lines.empty?
      end

      # @return [String] "File <path>:" and the fenced content, or a note for a file that does not exist yet
      def self.file_section(root, rel, protected)
        full = Repo::Paths.resolve_in_worktree(root, rel, protected: protected)
        return "File #{rel}: does not exist yet (the task creates it)." unless File.file?(full)

        "File #{rel}:\n#{Untrusted.fence(File.read(full, mode: 'rb').force_encoding(Encoding::UTF_8).scrub)}"
      end
      private_class_method :file_section, :summaries
    end
  end
end
