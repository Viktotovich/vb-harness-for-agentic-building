# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../model/tokens"
require_relative "../repo/paths"
require_relative "../untrusted"

module Harness
  module Task
    # sections: prompt-ready text blocks, each already fenced; tokens: their estimate; omitted: what did not fit.
    Bundle = Data.define(:sections, :tokens, :omitted)

    # Context bundle for the implementer and fixer (DESIGN.md 7). M3 packs priorities 1, 2, 3 and 6; the
    # map signatures (4) and docs (5) arrive with the context map.
    module Gather
      # @param task [Plan::Task]
      # @param root [String] worktree root
      # @param budget [Integer] tokens available for the task text and the bundle
      # @param protected [Array<String>] protectedPaths: never read into a prompt
      # @param task_text [String] the fenced task description (priority 1), counted against the budget
      # @param done [Array<String>] one-line summaries of completed tasks (priority 6)
      # @return [Bundle]
      # @raise [TaskTooLargeError] when the task and its modified files do not fit
      def self.build(task:, root:, budget:, protected:, task_text:, done: [])
        required = (task.files.modify + task.files.create).uniq.map { |rel| file_section(root, rel, protected) }
        need = Model::Tokens.estimate(task_text) + required.sum { |s| Model::Tokens.estimate(s) }
        if need > budget
          raise TaskTooLargeError, "split #{task.id}: its files need ~#{need} tokens, the budget is #{budget}"
        end

        sections = required.dup
        omitted = []
        used = need
        optional = task.files.read.map { |rel| [rel, file_section(root, rel, protected)] }
        optional << ["completed tasks", "Completed tasks:\n#{Untrusted.fence(done.join("\n"))}"] unless done.empty?
        optional.each do |name, text|
          cost = Model::Tokens.estimate(text)
          if used + cost <= budget
            sections << text
            used += cost
          else
            omitted << name
          end
        end
        Bundle.new(sections: sections.freeze, tokens: used, omitted: omitted.freeze)
      end

      # @return [String] "File <path>:" and the fenced content, or a note for a file that does not exist yet
      def self.file_section(root, rel, protected)
        full = Repo::Paths.resolve_in_worktree(root, rel, protected: protected)
        return "File #{rel}: does not exist yet (the task creates it)." unless File.file?(full)

        "File #{rel}:\n#{Untrusted.fence(File.read(full, mode: 'rb').force_encoding(Encoding::UTF_8).scrub)}"
      end
      private_class_method :file_section
    end
  end
end
