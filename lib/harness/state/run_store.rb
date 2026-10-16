# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"
require "securerandom"
require_relative "records"

module Harness
  module State
    # Files of one run under runs/<runId>/ (DESIGN.md 10.1). Every write is atomic.
    class RunStore
      # @return [String]
      attr_reader :run_id, :dir

      # @param now [Time]
      # @return [String] e.g. r20261016-142233-a1b2
      def self.new_run_id(now = Time.now)
        "r#{now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
      end

      # @param runs_dir [String]
      # @param run_id [String]
      def initialize(runs_dir:, run_id:)
        @run_id = run_id
        @dir = File.join(runs_dir, run_id)
      end

      # @return [String]
      def events_path = File.join(@dir, "events.jsonl")
      # @return [String]
      def records_dir = File.join(@dir, "records")
      # @return [String]
      def plan_path = File.join(@dir, "plan.json")
      # @return [String]
      def baseline_path = File.join(@dir, "baseline.json")

      # @param id [String] task id
      # @return [String]
      def task_dir(id) = File.join(@dir, "tasks", id)

      # @return [String]
      def lock_path = File.join(@dir, "harness.lock")

      # @return [String]
      def final_review_path = File.join(@dir, "final_review.json")

      # @param text [String] the feature request, saved as runs/<runId>/request.md
      # @return [void]
      def write_request(text)
        FileUtils.mkdir_p(@dir)
        File.write(File.join(@dir, "request.md"), text, encoding: "UTF-8")
      end

      # @return [String, nil]
      def read_request
        File.read(File.join(@dir, "request.md"), encoding: "UTF-8")
      rescue Errno::ENOENT
        nil
      end

      # @return [Boolean]
      def exist?
        File.file?(File.join(@dir, "run.json"))
      end

      # @param data [Hash]
      # @return [void]
      def write_run(data)
        State.write_json(File.join(@dir, "run.json"), data)
      end

      # @return [Hash] run.json, or {} when there is none yet
      def read_run
        State.read_json(File.join(@dir, "run.json"))
      rescue Errno::ENOENT
        {}
      end

      # Merge fields into run.json.
      # @param fields [Hash]
      # @return [Hash] the new content
      def update_run(fields)
        data = read_run.merge(fields)
        write_run(data)
        data
      end

      # @param id [String]
      # @param data [Hash] state, fixRounds, commit, reason, touched, created
      # @return [void]
      def write_task_state(id, data)
        State.write_json(File.join(task_dir(id), "state.json"), data)
      end

      # @param id [String]
      # @return [Hash, nil]
      def read_task_state(id)
        State.read_json(File.join(task_dir(id), "state.json"))
      rescue Errno::ENOENT
        nil
      end

      # @param id [String]
      # @param name [String] file name, e.g. "gates-1.json" or "blocked.patch"
      # @param content [String, Hash, Array] JSON data or text
      # @return [String] the path written
      def write_task_file(id, name, content)
        path = File.join(task_dir(id), name)
        if content.is_a?(String)
          FileUtils.mkdir_p(File.dirname(path))
          File.write("#{path}.tmp", content, encoding: "UTF-8")
          File.rename("#{path}.tmp", path)
        else
          State.write_json(path, content)
        end
        path
      end
    end
  end
end
