# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "set"
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
      # A test file by the common conventions: a .test. or .spec. (or _test / _spec) file name, or a file under a
      # tests, test, __tests__, spec or e2e folder. A field plan once named a page as its own test, and the unit
      # gate then ran the test runner on the page.
      TEST_FILE = %r{(?:\A|/)(?:tests?|__tests__|spec|e2e)/|[._](?:test|spec)\.[A-Za-z0-9]+\z}
      # @param plan [Plan]
      # @param root [String] worktree root
      # @param max_files [Integer] maxFilesPerTask
      # @param protected [Array<String>] protectedPaths
      # @param gates [Array<String>] gate names the stack defines
      # @param budget [Integer, nil] the implementer's token budget for the task and its files; nil skips the size check
      # @param unavailable [Hash{String=>String}] gates the baseline could not run here, with why
      # @param test_gates [Array<String>] gates that run a task's tests (scope "tests")
      # @return [Array<Issue>] empty when the plan passes
      def self.run(plan, root:, max_files:, protected:, gates:, budget: nil, unavailable: {}, test_gates: [])
        issues = cycle(plan)
        plan.tasks.each do |t|
          path_issues = paths(t, root, protected, created_before(plan, t))
          issues.concat(writes_nothing(t))
          issues.concat(path_issues)
          issues.concat(files_count(t, max_files))
          issues.concat(acceptance(t, gates, unavailable, test_gates))
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

      # @param stack [Gates::Stack]
      # @return [Array<String>] the gates that run a task's tests
      def self.test_gates(stack)
        stack.gates.values.select { |g| g.scope == "tests" }.map(&:name)
      end

      # Gates the baseline skipped (their tool is not installed, for example): no task can be proven with them.
      # @param baseline [Hash{String=>Gates::Result}]
      # @return [Hash{String=>String}] gate name => why
      def self.unavailable(baseline)
        baseline.select { |_, r| r.status == "skipped" }.to_h { |name, r| [name, r.reason.to_s[0, 120]] }
      end

      # Files created by the tasks a task depends on, directly or not: they exist by the time it runs.
      # @return [Set<String>]
      def self.created_before(plan, task)
        by_id = plan.tasks.to_h { |t| [t.id, t] }
        seen = {}
        todo = task.depends_on.dup
        until todo.empty?
          id = todo.shift
          next if seen[id] || !by_id.key?(id)

          seen[id] = true
          todo.concat(by_id[id].depends_on)
        end
        seen.keys.flat_map { |id| by_id[id].files.create }.to_set
      end

      # @param earlier [Set<String>] files an earlier task creates (see created_before)
      # @return [Array<Issue>]
      def self.paths(task, root, protected, earlier)
        listed = { "create" => task.files.create, "modify" => task.files.modify, "read" => task.files.read }
        listed.flat_map do |kind, list|
          list.filter_map do |rel|
            full = Repo::Paths.resolve_in_worktree(root, rel, protected: protected)
            exists = File.file?(full)
            if kind == "create" && File.exist?(full)
              Issue.new(task: task.id, reason: "plan.path_exists",
                        message: "#{task.id}: #{rel} already exists (files.create); list it under files.modify instead")
            elsif kind != "create" && !exists && !earlier.include?(rel)
              Issue.new(task: task.id, reason: "plan.missing_path",
                        message: "#{task.id}: #{rel} does not exist (files.#{kind}) and no task it depends on creates it; " \
                                 "add the task that creates it to dependsOn, or list only existing files")
            end
          rescue PathError => e
            why = e.reason == Repo::Paths::PROTECTED ? "is a protected path" : "is outside the repository"
            Issue.new(task: task.id, reason: "plan.protected_path", message: "#{task.id}: #{rel} #{why} and cannot be part of a task")
          end
        end
      end

      # @return [Array<Issue>]
      def self.acceptance(task, gates, unavailable, test_gates)
        provable = task.acceptance.select { |a| %w[gate test].include?(a.kind) }
        runnable = gates - unavailable.keys
        issues = []
        if provable.empty?
          issues << Issue.new(task: task.id, reason: "plan.no_acceptance",
                              message: "#{task.id} has no acceptance item of kind gate or test; add one so the task can be proven")
        end
        task.acceptance.select { |a| a.kind == "gate" && !gates.include?(a.gate) }.each do |a|
          issues << Issue.new(task: task.id, reason: "plan.unknown_gate",
                              message: "#{task.id}: there is no gate named #{a.gate}; use one of #{runnable.join(', ')}")
        end
        task.acceptance.select { |a| a.kind == "gate" && unavailable.key?(a.gate) }.each do |a|
          issues << Issue.new(task: task.id, reason: "plan.gate_unavailable",
                              message: "#{task.id}: the #{a.gate} gate cannot run in this repository (#{unavailable[a.gate]}); " \
                                       "use one of #{runnable.join(', ')}")
        end
        task.acceptance.select { |a| a.kind == "test" && a.path }.each do |a|
          next if TEST_FILE.match?(a.path.to_s)

          issues << Issue.new(task: task.id, reason: "plan.not_a_test_file",
                              message: "#{task.id}: the test item's path #{a.path} is not a test file; give a test path " \
                                       "such as tests/<name>.test.ts, or prove the task with a gate instead")
        end
        if task.acceptance.any? { |a| a.kind == "test" } && !test_gates.empty? && (test_gates - unavailable.keys).empty?
          issues << Issue.new(task: task.id, reason: "plan.gate_unavailable",
                              message: "#{task.id}: tests cannot run in this repository (#{test_gates.join(', ')}: " \
                                       "#{unavailable[test_gates.first]}); prove the task with one of #{runnable.join(', ')}")
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
      private_class_method :cycle, :writes_nothing, :files_count, :created_before, :paths, :acceptance, :size
    end
  end
end
