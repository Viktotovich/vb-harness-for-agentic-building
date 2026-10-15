# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "find"
require_relative "../errors"
require_relative "../gates/baseline"
require_relative "../model/client"
require_relative "../prompts"
require_relative "../repo/filters"
require_relative "../repo/paths"
require_relative "../task/edits"
require_relative "../untrusted"

module Harness
  module Review
    # status: confirmed (the test fails, so the claim holds) or question; reason: a confirm.* code for questions.
    Confirmation = Data.define(:claim, :status, :reason, :detail, :test_path, :test_content)

    # Confirm by test (DESIGN.md 8.4): the fixer writes a test that should fail if the claim is true, and the
    # harness runs it with the stack's test gate. A failing test confirms the claim; a passing test, or one that
    # cannot be written or run, sends the claim to the report's Questions (I8). The test is removed afterwards;
    # a confirmed claim carries it to its follow-up fix task.
    class Confirm
      TEST_NAME = /(?:\.(?:test|spec)\.[a-z]+|_test\.rb)\z/
      DEFAULT_SUFFIX = ".test.ts"
      MAX_CODE_LINES = 400
      MAX_EXAMPLE_BYTES = 3000

      # @param ctx [Context]
      # @param stack [Gates::Stack]
      # @param runner [Gates::Runner]
      # @param baseline [Hash{String=>Gates::Result}]
      # @param root [String] worktree root
      # @param name [String] used in the test file name, e.g. the task id
      def initialize(ctx:, stack:, runner:, baseline:, root:, name:)
        @ctx = ctx
        @stack = stack
        @runner = runner
        @baseline = baseline
        @root = root
        @name = name.gsub(/[^A-Za-z0-9-]/, "-")
      end

      # @param claim [Claim] an accepted claim
      # @return [Confirmation]
      def call(claim)
        gate = @stack.gates.values.find { |g| g.scope == "tests" && g.phase == "task" }
        return question(claim, "confirm.test_not_writable", "the stack has no test gate") unless gate

        example = example_test
        path = test_path(claim, example)
        @ctx.emit("review.confirm_test", "stage_started", subject: subject(claim), detail: path)
        edit_set = ask(claim, path, example)
        return question(claim, "confirm.test_not_writable", "the fixer wrote no test") unless edit_set

        applied = Task::Edits.apply(root: @root, edit_set: edit_set, modify: [], create: [path], protected: @stack.protected_paths)
        return question(claim, "confirm.test_not_writable", applied.rejections.map(&:message).join("; ")[0, 300]) unless applied.ok?

        content = File.read(File.join(@root, path), encoding: "UTF-8")
        cmp = Gates::Baseline.compare(@runner.run(gate, files: [], tests: [path]), @baseline[gate.name])
        if %w[skipped timeout].include?(cmp.current.status)
          question(claim, "confirm.test_not_writable", "the test could not be run: #{cmp.current.reason || cmp.current.status}")
        elsif cmp.ok?
          question(claim, "confirm.test_passes", "the test passes, so the claim is not shown")
        else
          @ctx.emit("review.confirm_test", "accepted", subject: subject(claim), detail: "#{path} fails: #{cmp.new_diagnostics.first&.message.to_s[0, 200]}")
          Confirmation.new(claim: claim, status: "confirmed", reason: nil, detail: "the test fails", test_path: path, test_content: content)
        end
      rescue ModelOutputError, ContextOverflowError, PathError => e
        question(claim, "confirm.test_not_writable", e.message[0, 300])
      ensure
        full = path && File.join(@root, path)
        File.delete(full) if full && File.file?(full)
      end

      private

      # @return [Task::EditSet, nil] nil when the fixer says no test can be written
      def ask(claim, path, example)
        f = claim.finding
        claim_text = ["file: #{f.file}", "line: #{f.line}", "problem: #{f.problem}", "trigger: #{claim.verdict&.fetch('trigger', '')}"].join("\n")
        user = Prompts.render("confirm_user", claim: Untrusted.fence(claim_text), code: Untrusted.fence(code_of(f.file)), path: path,
                                              example: example ? Untrusted.fence(example[1]) : "")
        parser = lambda do |obj|
          raise ParseError, "the reply is not a JSON object" unless obj.is_a?(Hash)
          next nil if Array(obj["tests"]).empty? && Array(obj["edits"]).empty?

          set = Task::EditSet.parse(obj)
          raise ParseError, "write exactly one test, at #{path}, and change nothing else" unless set.edits.empty? && set.tests.map(&:path) == [path]

          set
        end
        @ctx.client.complete(:fixer, Model::Messages.new(system: Prompts.render("confirm_system", path: path), user: user),
                             label: "#{@ctx.label}.confirm.#{claim.id}", schema: Task::EditSet::SCHEMA, parser: parser).value
      end

      # @return [String] the claim's file, numbered, at most MAX_CODE_LINES lines
      def code_of(rel)
        full = Repo::Paths.resolve_in_worktree(@root, rel, protected: @stack.protected_paths)
        lines = File.read(full, mode: "rb").force_encoding(Encoding::UTF_8).scrub.lines.first(MAX_CODE_LINES)
        "#{rel}:\n" + lines.each_with_index.map { |l, i| "#{(i + 1).to_s.rjust(5)}  #{l.chomp}" }.join("\n")
      rescue PathError, SystemCallError
        "#{rel}: (not readable)"
      end

      # @return [Array(String, String), nil] path and start of an existing test file
      def example_test
        found = nil
        Find.find(@root) do |full|
          rel = full.delete_prefix("#{@root}/")
          if File.directory?(full)
            Find.prune if full != @root && Repo::Filters.skip_reason("#{rel}/")
            next
          end
          next unless rel.match?(TEST_NAME) && !Repo::Paths.protected?(rel, @stack.protected_paths)

          found = rel if found.nil? || rel < found
        end
        found && [found, File.read(File.join(@root, found), encoding: "UTF-8").scrub[0, MAX_EXAMPLE_BYTES]]
      end

      # @return [String] a new test file next to the project's tests
      def test_path(claim, example)
        dir = example ? File.dirname(example[0]) : "tests"
        suffix = example ? example[0][TEST_NAME] : DEFAULT_SUFFIX
        base = suffix.start_with?("_") ? "harness_confirm_#{@name}_#{claim.id}".tr("-", "_") : "harness-confirm-#{@name}-#{claim.id}"
        dir == "." ? "#{base}#{suffix}" : "#{dir}/#{base}#{suffix}"
      end

      # @return [Confirmation]
      def question(claim, reason, detail)
        @ctx.emit("review.confirm_test", "question", subject: subject(claim), reason: reason, detail: detail.to_s[0, 300])
        Confirmation.new(claim: claim, status: "question", reason: reason, detail: detail, test_path: nil, test_content: nil)
      end

      # @return [String]
      def subject(claim) = "claim #{claim.id} (#{claim.finding.where})"
    end
  end
end
