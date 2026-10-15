# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../state/events"
require_relative "../state/reasons"
require_relative "render"

module Harness
  module Report
    # The progress view of DESIGN.md 11.5 as plain text, for `harness status`. Like the app's view it is built
    # from the event log (plus run.json and plan.json for names and order), never from anything else.
    module Status
      DONE = "✓"
      ACTIVE = "●"
      PENDING = "○"
      BLOCKED = "✕"
      SKIPPED = "↷"
      FINISHED = %w[done failed stopped plan_rejected].freeze
      TASK_STEPS = [%w[gather task.gather], %w[implement task.implement], %w[apply task.apply], %w[gates task.gates],
                    %w[fix task.fix]].freeze
      REVIEW_STEPS = [%w[discover review.discover], %w[verify review.verify], %w[judge review.judge], %w[support review.support],
                      %w[challenge review.challenge], %w[confirm-test review.confirm_test]].freeze
      TITLE_WIDTH = 28
      REASON_ROWS = 8

      # @param store [State::RunStore]
      # @return [String]
      def self.render(store)
        data = Render::Sources.load(store)
        fold = data.summary
        tasks = Array(data.plan["tasks"])
        lines = [header(data), stage_strip(data, tasks), ""]
        tasks.each { |t| lines.concat(task_lines(data, t, fold["tasks"][t["id"]])) }
        lines << "(no plan yet)" if tasks.empty?
        lines << ""
        lines.concat(outputs(data))
        lines.join("\n")
      end

      # @param store [State::RunStore]
      # @return [Hash] the same view as data, for --json
      def self.json(store)
        data = Render::Sources.load(store)
        { "run" => data.run_id, "status" => data.run["status"], "tasks" => data.states, "summary" => data.summary,
          "tokens" => tokens(data) }
      end

      # @param store [State::RunStore]
      # @return [Boolean] whether the run has stopped changing (watch ends)
      def self.finished?(store)
        FINISHED.include?(store.read_run["status"]) || store.read_run["status"] == "waiting" || store.read_run["status"] == "planned"
      end

      # @return [String]
      def self.header(data)
        t = data.summary["totals"]
        "Run #{data.run_id} · #{data.run['status'] || 'unknown'} · #{Render.duration(t['elapsedMs'])} · #{kilo(tokens(data))} tok"
      end

      # @return [String]
      def self.stage_strip(data, tasks)
        status = data.run["status"].to_s
        plan = if %w[planning waiting].include?(status) then ACTIVE
               elsif tasks.empty? then PENDING
               else DONE
               end
        finished = data.states.values.count { |s| %w[done blocked skipped].include?(s["state"]) }
        task_mark = if tasks.empty? || finished.zero? && status != "running" then PENDING
                    elsif finished == tasks.size then DONE
                    else ACTIVE
                    end
        "Plan #{plan} ── Tasks #{finished}/#{tasks.size} #{task_mark} ── Integration #{run_stage(data, 'integration')} ── " \
          "Final review #{run_stage(data, 'final_review')} ── Report #{run_stage(data, 'report')}"
      end

      # @return [String]
      def self.run_stage(data, stage)
        kinds = data.events.select { |e| e["stage"] == stage && e["task"].nil? }.map { |e| e["kind"] }
        return DONE if kinds.include?("stage_finished")

        kinds.include?("stage_started") ? ACTIVE : PENDING
      end

      # @return [Array<String>]
      def self.task_lines(data, task, folded)
        state = data.states[task["id"]] || {}
        title = Render.line(task["title"], TITLE_WIDTH).ljust(TITLE_WIDTH)
        head = "#{task['id'].ljust(5)} #{title} "
        case state["state"]
        when "done"
          gates = data.last_gates(task["id"]).values
          passed = gates.count { |g| g["status"] == "passed" }
          commit = state["commit"] ? "committed #{state['commit'][0, 7]}" : "no changes"
          ["#{head}#{DONE} #{commit.ljust(18)} gates #{passed}/#{gates.size}   fix #{state['fixRounds'].to_i}"]
        when "blocked" then ["#{head}#{BLOCKED} blocked: #{State::Reasons.text(state['reason'])} (tasks/#{task['id']}/blocked.patch)"]
        when "skipped" then ["#{head}#{SKIPPED} skipped: #{Render.line(state['reason'], 60)}"]
        when "pending", nil
          waiting = Array(task["dependsOn"]).reject { |d| data.states.dig(d, "state") == "done" }
          ["#{head}#{PENDING}#{waiting.empty? ? '' : " waiting on #{waiting.join(', ')}"}"]
        else
          stage = folded&.fetch("stage", nil).to_s
          [
            "#{head}#{ACTIVE} #{stage.sub('.', ' › ')}   (attempt #{[folded&.fetch('attempts', 0).to_i, 1].max})",
            "      #{steps(data, task['id'], stage)}"
          ]
        end
      end

      # The sub-stages of the active task: done, active or pending.
      # @return [String]
      def self.steps(data, id, current)
        seen = data.events.select { |e| e["task"] == id }.map { |e| e["stage"] }.uniq
        mark = ->(stage) { stage == current ? ACTIVE : (seen.include?(stage) ? DONE : PENDING) }
        task = TASK_STEPS.map { |name, stage| "#{name} #{mark.call(stage)}" }
        review = REVIEW_STEPS.map { |name, stage| "#{name} #{mark.call(stage)}" }
        "#{task.join(' ')} review: #{review.join(' ')}"
      end

      # @return [Array<String>]
      def self.outputs(data)
        t = data.summary["totals"]
        lines = ["Outputs  #{t['produced']} produced · #{t['accepted']} accepted · #{t['rejected']} rejected " \
                 "(#{(t['rejectionRate'] * 100).round}%)"]
        stage_of = data.events.select { |e| e["kind"] == "rejected" && e["reason"] }.to_h { |e| [e["reason"], e["stage"]] }
        data.summary["reasons"].sort_by { |code, n| [-n, code] }.first(REASON_ROWS).each do |code, n|
          lines << "  #{n.to_s.rjust(3)}  #{State::Reasons.text(code).ljust(34)} #{stage_of[code]}"
        end
        Array(data.run["questions"]).each { |q| lines << "Question: #{Render.line(q)} (answer with: harness answer #{data.run_id})" }
        lines
      end

      # @return [Integer] tokens in and out over every recorded model call
      def self.tokens(data)
        data.records.sum { |r| r.dig("usage", "in").to_i + r.dig("usage", "out").to_i }
      end

      # @return [String] e.g. "38.2K"
      def self.kilo(n)
        n < 1000 ? n.to_s : "#{(n / 1000.0).round(1)}K"
      end
      private_class_method :header, :stage_strip, :run_stage, :task_lines, :steps, :outputs, :tokens, :kilo
    end
  end
end
