# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../repo/paths"
require_relative "../task/gather"
require_relative "../untrusted"
require_relative "plan"

module Harness
  module Plan
    # One failed plan check: a reason code (DESIGN.md 10.3) and a message fed back to the planner.
    Issue = Data.define(:task, :reason, :message)

    # Plan checks against the worktree (DESIGN.md 5.3).
    module Checks
      # @param plan [Plan]
      # @param root [String] worktree root
      # @param max_files [Integer] maxFilesPerTask
      # @param protected [Array<String>] protectedPaths
      # @param gates [Array<String>] gate names the stack defines
      # @param budget [Integer, nil] the implementer's token budget for the task and its files; nil skips the size check
      # @return [Array<Issue>] empty when the plan passes
      def self.run(plan, root:, max_files:, protected:, gates:, budget: nil)
        issues = cycle(plan)
        plan.tasks.each do |t|
          path_issues = paths(t, root, protected)
          issues.concat(writes_nothing(t))
          issues.concat(path_issues)
          issues.concat(files_count(t, max_files))
          issues.concat(acceptance(t, gates))
          issues.concat(size(t, root, protected, budget)) if budget && path_issues.empty?
        end
        issues
      end

      # @return [Array<Issue>]
      def self.cycle(plan)
        plan.ordered
        []
      rescue ParseError
        ids = plan.tasks.reject { |t| t.depends_on.empty? }.map(&:id)
        [Issue.new(task: nil, reason: "plan.cycle",
                   message: "tasks #{ids.join(', ')} depend on each other in a cycle; remove a dependency so they can run in order")]
      end

      # A task that only inspects or analyses has nothing a gate can prove; its reading belongs to the task that
      # makes the change.
      # @return [Array<Issue>]
      def self.writes_nothing(task)
        return [] unless (task.files.create + task.files.modify).empty?

        [Issue.new(task: task.id, reason: "plan.no_changes",
                   message: "#{task.id} creates and modifies no files. Every task must change something: fold the inspection " \
                            "into the task that writes (list what it reads under files.read) and remove #{task.id}")]
      end

      # @return [Array<Issue>]
      def self.files_count(task, max_files)
        n = (task.files.create + task.files.modify).uniq.size
        return [] if n <= max_files

        [Issue.new(task: task.id, reason: "plan.too_many_files",
                   message: "#{task.id} creates or modifies #{n} files; the limit is #{max_files} per task. Split it into smaller tasks")]
      end

      # @return [Array<Issue>]
      def self.paths(task, root, protected)
        listed = { "create" => task.files.create, "modify" => task.files.modify, "read" => task.files.read }
        listed.flat_map do |kind, list|
          list.filter_map do |rel|
            full = Repo::Paths.resolve_in_worktree(root, rel, protected: protected)
            exists = File.file?(full)
            if kind == "create" && File.exist?(full)
              Issue.new(task: task.id, reason: "plan.path_exists",
                        message: "#{task.id}: #{rel} already exists (files.create); list it under files.modify instead")
            elsif kind != "create" && !exists
              Issue.new(task: task.id, reason: "plan.missing_path",
                        message: "#{task.id}: #{rel} does not exist (files.#{kind}); only existing files can be modified or read")
            end
          rescue PathError => e
            why = e.reason == Repo::Paths::PROTECTED ? "is a protected path" : "is outside the repository"
            Issue.new(task: task.id, reason: "plan.protected_path", message: "#{task.id}: #{rel} #{why} and cannot be part of a task")
          end
        end
      end

      # @return [Array<Issue>]
      def self.acceptance(task, gates)
        provable = task.acceptance.select { |a| %w[gate test].include?(a.kind) }
        issues = []
        if provable.empty?
          issues << Issue.new(task: task.id, reason: "plan.no_acceptance",
                              message: "#{task.id} has no acceptance item of kind gate or test; add one so the task can be proven")
        end
        task.acceptance.select { |a| a.kind == "gate" && !gates.include?(a.gate) }.each do |a|
          issues << Issue.new(task: task.id, reason: "plan.unknown_gate",
                              message: "#{task.id}: there is no gate named #{a.gate}; use one of #{gates.join(', ')}")
        end
        issues
      end

      # @return [Array<Issue>]
      def self.size(task, root, protected, budget)
        Harness::Task::Gather.build(task: task, root: root, budget: budget, protected: protected,
                           task_text: Untrusted.fence(task.prompt_text))
        []
      rescue TaskTooLargeError => e
        [Issue.new(task: task.id, reason: "plan.too_large_for_context", message: e.message)]
      end
      private_class_method :cycle, :writes_nothing, :files_count, :paths, :acceptance, :size
    end
  end
end
