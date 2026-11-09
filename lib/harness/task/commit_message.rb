# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC
# frozen_string_literal: true

module Harness
  module Task
    # The message for a task's commit: "<type>: <title>" in Conventional Commits form when the plan gave a type,
    # then a trailer from the config template.
    module CommitMessage
      PLACEHOLDERS = %w[model version checks gates].freeze
      DEFAULT_TRAILER = "Gates passed: {gates}"

      # @param task [Plan::Task]
      # @param template [String] the trailer template (config commit.trailer)
      # @param model [String] the implementer's model id
      # @param version [String] the harness version
      # @param gates [Array<String>] gates that passed for this task
      # @return [String]
      def self.build(task:, template:, model:, version:, gates:)
        values = { "model" => model, "version" => version, "checks" => gates.size.to_s, "gates" => gates.join(", ") }
        trailer = template.gsub(/\{(\w+)\}/) { values.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
        "#{subject(task)}\n\n#{trailer}"
      end

      # @param task [Plan::Task]
      # @return [String] "feat: add the badge" with a type, "T1: Add the badge" without
      def self.subject(task)
        return "#{task.id}: #{task.title}" unless task.type

        title = task.title.sub(/\A#{task.type}:\s*/i, "")
        title = title[0].downcase + title[1..] if title.match?(/\A[A-Z][a-z]/)
        "#{task.type}: #{title}"
      end
    end
  end
end
