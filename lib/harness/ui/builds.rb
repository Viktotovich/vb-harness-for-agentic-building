# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../report/render"
require_relative "../state/events"
require_relative "../state/lock"
require_relative "../state/reasons"
require_relative "../state/notes"
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
      # @param finished [#call, nil] (run id) -> void, called in the build's thread once its pipeline step returns
      # @param fixes [#call, nil] (run.json hash) -> Hash merged into the card's view: "setupFixes" (one-click setup
      #   for a failed run) and "canPreview" (a finished build's copy can be served)
      def initialize(runs_dir:, pipeline:, sleeper: ->(s) { sleep(s) }, finished: nil, fixes: nil)
        @fixes = fixes
        @runs_dir = runs_dir
        @pipeline = pipeline
        @sleeper = sleeper
        @finished = finished
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

      # Continue a stopped or failed run where it left off (harness resume, from the app). Committed tasks are kept.
      # @param id [String]
      # @return [String] the run id
      # @raise [ConfigError] when there is no such run, it is still going, or it cannot be resumed
      def resume(id)
        info = run_info(id)
        raise ConfigError, LOST if info["error"] == LOST

        status = info["status"]
        unless %w[stopped failed].include?(status)
          raise ConfigError, "run #{id} cannot be resumed (status: #{status}); only a stopped or failed run can"
        end

        background(id) { |stop| @pipeline.call.resume(id, stop: stop) }
        id
      end

      # @param id [String]
      # @return [Hash] run.json, with "status" "stopped" for a run whose process ended without saying so
      # @raise [ConfigError] when there is no such run
      def run_info(id)
        s = store(id, events_only: true)
        shown(id, s, s.read_run)
      end

      # What a run with no run.json says: before 0.1.49 a build that failed at intake ended before saving one, so
      # its card waited for ever. Nothing can resume it; it can only be started again.
      LOST = "this build ended before it saved its status, so its reason was not kept; start it again"

      # run.json as the app shows it: a run nobody holds any more is "stopped" (Resume continues it), or "failed"
      # with LOST when it never saved a status at all.
      # @param id [String]
      # @param store [State::RunStore]
      # @param run [Hash] run.json, {} when there is none
      # @return [Hash]
      def shown(id, store, run)
        return run unless interrupted?(id, store, run)
        return run.merge("status" => "failed", "exitCode" => 2, "error" => LOST) if run["status"].nil?

        run.merge("status" => "stopped", "interrupted" => true)
      end

      # A run that says it is going, or says nothing at all, but no process holds it: neither a thread here nor a
      # live harness.lock (the app or the command line that ran it was closed or crashed).
      # @return [Boolean]
      def interrupted?(id, store, run)
        return false unless [nil, "running", "planning", "starting"].include?(run["status"]) && !running?(id)

        holder = State.read_json(store.lock_path)
        !(holder.is_a?(Hash) && holder["pid"].is_a?(Integer) && State::Lock.alive?(holder["pid"]))
      rescue Errno::ENOENT, JSON::ParserError
        true
      end

      # @param id [String]
      # @return [String, nil] the run's status ("running", "waiting", "done", ...), or nil when there is no such run
      def status(id)
        return nil unless id.is_a?(String) && id.match?(RUN_ID)

        s = State::RunStore.new(runs_dir: @runs_dir, run_id: id)
        return nil unless s.exist? || File.file?(s.events_path)

        shown(id, s, s.read_run)["status"]
      rescue JSON::ParserError, SystemCallError
        nil
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

      # A note to a running agent-mode run (State::Notes): steering, or the answer to the agent's question.
      # @param id [String]
      # @param text [String]
      # @return [Integer] the note's number
      # @raise [ConfigError, ParseError]
      def note(id, text)
        State::Notes.new(store(id).dir).add(text.to_s)
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
        sent = nil
        idle = 0.0
        until sse.closed?
          fresh = State::Events.read(store.events_path, after: seq)
          fresh.each do |e|
            sse.event("event", e.merge("reasonText" => e["reason"] ? State::Reasons.text(e["reason"]) : nil), id: e["seq"])
            seq = e["seq"]
          end
          run = shown(id, store, store.read_run)
          plan = tasks(store)
          job = @mutex.synchronize { @jobs[id] }
          asked = job ? @mutex.synchronize { job[:stop] } : false
          # agentQuestion and mode: an agent-mode run's pending question, and whether notes can steer it.
          view = run.slice("status", "questions", "exitCode", "branch", "agentQuestion", "mode", "error").merge("tasks" => plan, "stopping" => asked)
          view.merge!(@fixes.call(run)) if @fixes
          if view != sent
            status = run["status"]
            sent = view
            sse.event("run", view)
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

      # @param id [String]
      # @param events_only [Boolean] also accept a run that has an event log but never wrote run.json (see LOST)
      # @return [State::RunStore]
      # @raise [ConfigError]
      def store(id, events_only: false)
        raise ConfigError, "no run #{id.to_s[0, 40]}" unless id.is_a?(String) && id.match?(RUN_ID)

        s = State::RunStore.new(runs_dir: @runs_dir, run_id: id)
        raise ConfigError, "no run #{id}" unless s.exist? || (events_only && File.file?(s.events_path))

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
            @finished&.call(id)
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
