# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../report/render"
require_relative "../state/events"
require_relative "../state/reasons"
require_relative "../state/run_store"

module Harness
  module UI
    # Build mode (DESIGN.md 11.3, 11.5): a message becomes request.md for a pipeline run in the background. Its
    # events stream to the browser, replayed from any seq, so a reload loses nothing. Answers to blocking questions
    # come from the text box.
    class Builds
      RUN_ID = /\Ar\d{8}-\d{6}-\h{4}\z/
      WAITING = %w[waiting planned].freeze
      FINISHED = %w[done failed stopped plan_rejected].freeze
      POLL = 0.25
      PING = 15

      # @param runs_dir [String]
      # @param pipeline [#call] -> Pipeline (built when a run starts, so config changes apply)
      # @param sleeper [#call]
      def initialize(runs_dir:, pipeline:, sleeper: ->(s) { sleep(s) })
        @runs_dir = runs_dir
        @pipeline = pipeline
        @sleeper = sleeper
        @jobs = {}
        @mutex = Mutex.new
      end

      # @param request [String]
      # @param repo [String] a local git repository
      # @return [String] the run id
      # @raise [ParseError] when the request is empty or the repository is not a folder
      def start(request:, repo:)
        raise ParseError, "write what to build" if request.to_s.strip.empty?
        raise ParseError, "the repository #{repo.to_s[0, 200]} is not a folder" unless repo.is_a?(String) && File.directory?(repo)

        id = State::RunStore.new_run_id
        background(id) { |stop| @pipeline.call.start(repo: repo, request: request, run_id: id, stop: stop) }
        id
      end

      # @param id [String]
      # @param answers [Array<String>]
      # @return [void]
      # @raise [ConfigError, ParseError]
      def answer(id, answers)
        store = store(id)
        raise ParseError, "answers must be a list of strings" unless answers.is_a?(Array) && answers.all?(String)

        questions = Array(store.read_run["questions"])
        raise ConfigError, "run #{id} is not waiting for answers" if questions.empty?
        raise ConfigError, "#{questions.size} questions need #{questions.size} answers" unless answers.size == questions.size

        background(id) { |stop| @pipeline.call.answer(id, answers, stop: stop) }
      end

      # Ask a run going in this process to stop at its next safe point (between tasks, see Run#execute). It then
      # ends "stopped" with its committed tasks kept, and harness resume continues it.
      # @param id [String]
      # @return [Boolean] whether a running build was asked to stop
      # @raise [ConfigError] when there is no such run
      def stop(id)
        store(id)
        @mutex.synchronize do
          job = @jobs[id]
          next false unless job&.fetch(:thread)&.alive?

          job[:stop] = true
        end
      end

      # @param id [String]
      # @return [String] report.md
      # @raise [ConfigError]
      def report(id)
        Report::Render.markdown(store(id))
      end

      # Replay events after seq, then follow the log until the run stops changing. The "run" event also says
      # whether a stop was asked for and the run has not reached its safe point yet ("stopping").
      # @param id [String]
      # @param after [Integer]
      # @param sse [SSE]
      # @return [void]
      def events(id, after, sse)
        raise ConfigError, "no run #{id}" unless id.is_a?(String) && id.match?(RUN_ID)

        store = State::RunStore.new(runs_dir: @runs_dir, run_id: id)
        seq = after
        status = nil
        shown = nil
        stopping = false
        idle = 0.0
        until sse.closed?
          fresh = State::Events.read(store.events_path, after: seq)
          fresh.each do |e|
            sse.event("event", e.merge("reasonText" => e["reason"] ? State::Reasons.text(e["reason"]) : nil), id: e["seq"])
            seq = e["seq"]
          end
          run = store.read_run
          plan = tasks(store)
          job = @mutex.synchronize { @jobs[id] }
          asked = job ? @mutex.synchronize { job[:stop] } : false
          if run["status"] != status || plan != shown || asked != stopping
            status = run["status"]
            shown = plan
            stopping = asked
            sse.event("run", run.slice("status", "questions", "exitCode", "branch").merge("tasks" => plan, "stopping" => asked))
          end
          sse.event("failed", { "error" => job[:error] }) if job && job[:error] && !job[:reported] && (job[:reported] = true)
          running = job && job[:thread].alive?
          break sse.event("end", { "status" => status }) if !running && (FINISHED.include?(status) || WAITING.include?(status) || job&.fetch(:error, nil))

          idle = fresh.empty? ? idle + POLL : 0.0
          if idle >= PING
            sse.event("ping", {})
            idle = 0.0
          end
          @sleeper.call(POLL)
        end
      end

      # @param id [String]
      # @return [Boolean] whether a run is going in this process
      def running?(id) = @mutex.synchronize { @jobs[id]&.fetch(:thread)&.alive? } || false

      private

      # The plan's tasks as the progress view needs them (titles are planner output; the page shows them as text).
      # @return [Array<Hash>]
      def tasks(store)
        plan = State.read_json(store.plan_path)
        Array(plan["tasks"]).map { |t| { "id" => t["id"], "title" => t["title"], "dependsOn" => Array(t["dependsOn"]) } }
      rescue Errno::ENOENT, JSON::ParserError
        []
      end

      # @return [State::RunStore]
      # @raise [ConfigError]
      def store(id)
        raise ConfigError, "no run #{id.to_s[0, 40]}" unless id.is_a?(String) && id.match?(RUN_ID)

        s = State::RunStore.new(runs_dir: @runs_dir, run_id: id)
        raise ConfigError, "no run #{id}" unless s.exist?

        s
      end

      # A run whose thread raised would otherwise stay "running" forever: record the error and mark it failed.
      # @param id [String]
      # @param message [String]
      # @return [void]
      def crashed(id, message)
        store = State::RunStore.new(runs_dir: @runs_dir, run_id: id)
        return unless store.exist?
        return if FINISHED.include?(store.read_run["status"])

        State::Events.new(path: store.events_path, run_id: id)
                     .emit(stage: "report", kind: "rejected", reason: "harness.crashed", detail: message)
        store.update_run({ "status" => "failed", "exitCode" => 1, "error" => message })
      rescue StandardError
        nil
      end

      # Run the block in a thread; it gets a stop check (-> Boolean) to pass to the pipeline.
      # @return [void]
      def background(id)
        @mutex.synchronize do
          raise ConfigError, "run #{id} is busy" if @jobs[id]&.fetch(:thread)&.alive?

          job = { error: nil, reported: false, stop: false }
          stop = -> { @mutex.synchronize { job[:stop] } }
          job[:thread] = Thread.new do
            yield stop
          rescue StandardError => e
            job[:error] = e.message[0, 500]
            crashed(id, job[:error])
          end
          @jobs[id] = job
        end
      end
    end
  end
end
