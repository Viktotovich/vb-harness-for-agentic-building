# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../parse"

module Harness
  module Plan
    TASK_ID = /\A[A-Za-z][A-Za-z0-9_-]{0,15}\z/
    ACCEPTANCE_KINDS = %w[gate test assert].freeze

    # kind gate: gate; kind test: path, write, describe; kind assert: text.
    Acceptance = Data.define(:kind, :gate, :path, :write, :describe, :text) do
      # @return [String] one line for prompts and reports
      def summary
        case kind
        when "gate" then "check #{gate} passes"
        when "test" then "test #{path}#{write ? ' (write it)' : ''}: #{describe}"
        else "review: #{text}"
        end
      end
    end

    Files = Data.define(:create, :modify, :read)

    # One small task (DESIGN.md 5.3).
    Task = Data.define(:id, :title, :intent, :files, :depends_on, :acceptance) do
      # @return [Array<String>] test paths the task may write
      def test_paths
        acceptance.select { |a| a.kind == "test" && a.write }.map(&:path)
      end

      # @return [Array<String>] every path the task may write
      def writable
        (files.create + files.modify + test_paths).uniq
      end
    end

    Question = Data.define(:text, :blocking)

    # A validated plan. Structural checks against the repo (paths, sizes) live in plan/checks.rb.
    Plan = Data.define(:tasks, :questions) do
      # @param id [String]
      # @return [Task, nil]
      def task(id)
        tasks.find { |t| t.id == id }
      end

      # Tasks in dependency order, keeping the plan's order where it is free.
      # @return [Array<Task>]
      # @raise [ParseError] on a dependency cycle
      def ordered
        done = {}
        out = []
        until out.size == tasks.size
          ready = tasks.find { |t| !done[t.id] && t.depends_on.all? { |d| done[d] } }
          raise ParseError, "tasks: dependency cycle among #{(tasks.map(&:id) - out.map(&:id)).join(', ')}" unless ready

          done[ready.id] = true
          out << ready
        end
        out
      end

      # @param id [String]
      # @return [Array<String>] ids of every task that depends on id, directly or not
      def dependants(id)
        direct = tasks.select { |t| t.depends_on.include?(id) }.map(&:id)
        (direct + direct.flat_map { |d| dependants(d) }).uniq
      end

      # @return [Hash] the plan in its JSON form
      def to_json_hash
        { "tasks" => tasks.map { |t| PlanParser.task_json(t) },
          "questions" => questions.map { |q| { "text" => q.text, "blocking" => q.blocking } } }
      end
    end

    # Strict parsing of planner output and plan files (DESIGN.md 5.3).
    module PlanParser
      # @param raw [Hash]
      # @return [Plan]
      # @raise [ParseError] with the exact path, e.g. "tasks[2].files.modify: expected array of strings, got nil"
      def self.parse(raw)
        h = Parse.hash!(raw, "plan")
        Parse.known_keys!(h, %w[tasks questions], "")
        tasks = h["tasks"]
        Parse.fail!("tasks", "array", tasks) unless tasks.is_a?(Array)
        parsed = tasks.each_with_index.map { |t, i| parse_task(t, "tasks[#{i}]") }
        check_ids!(parsed)
        questions = h.fetch("questions", [])
        Parse.fail!("questions", "array", questions) unless questions.is_a?(Array)
        Plan.new(tasks: parsed.freeze, questions: questions.each_with_index.map { |q, i| parse_question(q, "questions[#{i}]") }.freeze)
      end

      # @return [Task]
      def self.parse_task(raw, path)
        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, %w[id title intent files dependsOn acceptance], path)
        id = Parse.str!(h["id"], "#{path}.id")
        Parse.fail!("#{path}.id", "id like T1", id) unless id.match?(TASK_ID)
        files = Parse.hash!(h["files"], "#{path}.files")
        Parse.known_keys!(files, %w[create modify read], "#{path}.files")
        acceptance = h["acceptance"]
        Parse.fail!("#{path}.acceptance", "array", acceptance) unless acceptance.is_a?(Array)
        Task.new(
          id: id, title: Parse.str!(h["title"], "#{path}.title"), intent: Parse.str!(h["intent"], "#{path}.intent"),
          files: Files.new(**%w[create modify read].to_h do |k|
            [k.to_sym, Parse.strings!(files.fetch(k, []), "#{path}.files.#{k}").dup.freeze]
          end),
          depends_on: Parse.strings!(h.fetch("dependsOn", []), "#{path}.dependsOn").dup.freeze,
          acceptance: acceptance.each_with_index.map { |a, i| parse_acceptance(a, "#{path}.acceptance[#{i}]") }.freeze
        )
      end

      # @return [Acceptance]
      def self.parse_acceptance(raw, path)
        h = Parse.hash!(raw, path)
        kind = Parse.enum!(h["kind"], "#{path}.kind", ACCEPTANCE_KINDS)
        case kind
        when "gate"
          Parse.known_keys!(h, %w[kind gate], path)
          Acceptance.new(kind: kind, gate: Parse.str!(h["gate"], "#{path}.gate"), path: nil, write: false, describe: nil, text: nil)
        when "test"
          Parse.known_keys!(h, %w[kind path write describe], path)
          Acceptance.new(kind: kind, gate: nil, path: Parse.str!(h["path"], "#{path}.path"),
                         write: Parse.bool!(h.fetch("write", false), "#{path}.write"),
                         describe: Parse.str!(h["describe"], "#{path}.describe"), text: nil)
        else
          Parse.known_keys!(h, %w[kind text], path)
          Acceptance.new(kind: kind, gate: nil, path: nil, write: false, describe: nil, text: Parse.str!(h["text"], "#{path}.text"))
        end
      end

      # @return [Question]
      def self.parse_question(raw, path)
        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, %w[text blocking], path)
        Question.new(text: Parse.str!(h["text"], "#{path}.text"), blocking: Parse.bool!(h.fetch("blocking", false), "#{path}.blocking"))
      end

      # @return [void]
      def self.check_ids!(tasks)
        seen = {}
        tasks.each_with_index do |t, i|
          raise ParseError, "tasks[#{i}].id: duplicate id #{t.id}" if seen[t.id]

          seen[t.id] = true
        end
        tasks.each_with_index do |t, i|
          t.depends_on.each do |d|
            raise ParseError, "tasks[#{i}].dependsOn: no task #{d}" unless seen[d]
            raise ParseError, "tasks[#{i}].dependsOn: a task cannot depend on itself" if d == t.id
          end
        end
      end

      # @param t [Task]
      # @return [Hash]
      def self.task_json(t)
        acc = t.acceptance.map do |a|
          case a.kind
          when "gate" then { "kind" => "gate", "gate" => a.gate }
          when "test" then { "kind" => "test", "path" => a.path, "write" => a.write, "describe" => a.describe }
          else { "kind" => "assert", "text" => a.text }
          end
        end
        { "id" => t.id, "title" => t.title, "intent" => t.intent,
          "files" => { "create" => t.files.create, "modify" => t.files.modify, "read" => t.files.read },
          "dependsOn" => t.depends_on, "acceptance" => acc }
      end
      private_class_method :parse_task, :parse_acceptance, :parse_question, :check_ids!
    end
  end
end
