# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"
require "time"
require_relative "reasons"
require_relative "records"

module Harness
  module State
    # Append-only event log runs/<runId>/events.jsonl (DESIGN.md 10.3): every stage transition and every
    # output the harness throws away. The progress view, status, the report and eval metrics read only this.
    class Events
      KINDS = %w[stage_started stage_finished accepted rejected retried split skipped blocked question done].freeze
      STAGES = %w[
        intake map plan plan.check
        task.gather task.implement task.apply task.gates task.fix
        review.discover review.reconcile review.verify review.judge review.support review.challenge review.confirm_test
        task.commit integration final_review report
      ].freeze
      FIELDS = %i[task subject reason detail attempt model profile tokens ms].freeze

      # @return [String]
      attr_reader :path

      # @param path [String] events.jsonl
      # @param run_id [String]
      # @param clock [#call] returns the current Time
      def initialize(path:, run_id:, clock: -> { Time.now })
        @path = path
        @run_id = run_id
        @clock = clock
        @mutex = Mutex.new
        @seq = self.class.read(path).last&.fetch("seq", 0) || 0
      end

      # Append one event. A task's final outcome uses kind done, blocked or skipped with subject "task".
      # @param stage [String] one of STAGES
      # @param kind [String] one of KINDS
      # @param fields [Hash] keys from FIELDS
      # @return [Hash] the event written
      # @raise [ArgumentError] on an unknown stage, kind, field or reason code
      def emit(stage:, kind:, **fields)
        raise ArgumentError, "unknown event stage #{stage.inspect}" unless STAGES.include?(stage)
        raise ArgumentError, "unknown event kind #{kind.inspect}" unless KINDS.include?(kind)

        unknown = fields.keys - FIELDS
        raise ArgumentError, "unknown event fields #{unknown.join(', ')}" unless unknown.empty?
        raise ArgumentError, "unknown reason code #{fields[:reason].inspect}" if fields[:reason] && !Reasons.valid?(fields[:reason])

        @mutex.synchronize do
          @seq += 1
          event = { "seq" => @seq, "at" => @clock.call.utc.iso8601, "run" => @run_id, "stage" => stage, "kind" => kind }
          fields.each { |k, v| event[k.to_s] = v unless v.nil? }
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, "#{JSON.generate(event)}\n", mode: "a", encoding: "UTF-8")
          event
        end
      end

      # @param path [String]
      # @param after [Integer] only events with seq greater than this
      # @return [Array<Hash>] events in order; a torn last line (crash mid-write) is ignored
      def self.read(path, after: 0)
        return [] unless File.file?(path)

        File.foreach(path, encoding: "UTF-8").filter_map do |line|
          event = JSON.parse(line)
          event if event.is_a?(Hash) && event["seq"].to_i > after
        rescue JSON::ParserError
          nil
        end
      end

      # Fold the log into counters (cached in summary.json next to it, rebuilt when stale or missing).
      # @param path [String] events.jsonl
      # @return [Hash] "stages", "reasons", "tasks", "totals", "seq"
      def self.summary(path)
        cache = File.join(File.dirname(path), "summary.json")
        events = read(path)
        last = events.last&.fetch("seq", 0) || 0
        cached = begin
          JSON.parse(File.read(cache, encoding: "UTF-8"))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end
        return cached if cached.is_a?(Hash) && cached["seq"] == last

        fold(events).tap { |s| State.write_json(cache, s) }
      end

      # @param events [Array<Hash>]
      # @return [Hash]
      def self.fold(events)
        stages = Hash.new { |h, k| h[k] = { "started" => 0, "accepted" => 0, "rejected" => 0, "ms" => 0 } }
        reasons = Hash.new(0)
        tasks = {}
        totals = { "produced" => 0, "accepted" => 0, "rejected" => 0, "tokensIn" => 0, "tokensOut" => 0 }
        events.each do |e|
          s = stages[e["stage"]]
          s["started"] += 1 if e["kind"] == "stage_started"
          s["ms"] += e["ms"].to_i
          if %w[accepted rejected].include?(e["kind"])
            s[e["kind"]] += 1
            totals[e["kind"]] += 1
            totals["produced"] += 1
          end
          reasons[e["reason"]] += 1 if e["kind"] == "rejected" && e["reason"]
          if (tok = e["tokens"]).is_a?(Hash)
            totals["tokensIn"] += tok["in"].to_i
            totals["tokensOut"] += tok["out"].to_i
          end
          track_task(tasks, e) if e["task"]
        end
        totals["rejectionRate"] = totals["produced"].zero? ? 0.0 : (totals["rejected"].to_f / totals["produced"]).round(4)
        totals["elapsedMs"] = elapsed_ms(events)
        { "seq" => events.last&.fetch("seq", 0) || 0, "stages" => stages, "reasons" => reasons, "tasks" => tasks, "totals" => totals }
      end

      # @return [void]
      def self.track_task(tasks, e)
        t = tasks[e["task"]] ||= { "stage" => nil, "status" => "pending", "attempts" => 0 }
        t["stage"] = e["stage"]
        t["attempts"] = [t["attempts"], e["attempt"].to_i].max
        # A task's own outcome is the done/blocked/skipped event whose subject is "task".
        if %w[done blocked skipped].include?(e["kind"]) && e["subject"] == "task"
          t["status"] = e["kind"]
        elsif t["status"] == "pending"
          t["status"] = "running"
        end
      end

      # @return [Integer]
      def self.elapsed_ms(events)
        return 0 if events.size < 2

        ((Time.iso8601(events.last["at"]) - Time.iso8601(events.first["at"])) * 1000).round
      rescue ArgumentError
        0
      end
      private_class_method :track_task, :elapsed_ms
    end
  end
end
