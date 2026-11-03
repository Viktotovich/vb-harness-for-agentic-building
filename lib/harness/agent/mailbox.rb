# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../state/notes"

module Harness
  module Agent
    # The user's side of a running agent: their notes reach the agent between turns (#inbox), and an agent's
    # question waits for their answer (#ask). Which notes the agent has seen is kept in run.json ("notesRead"), so
    # a note reaches the agent once, across tasks and after a resume.
    class Mailbox
      POLL = 1.0

      # @param store [State::RunStore]
      # @param events [State::Events]
      # @param task_id [String]
      # @param timeout [Integer] seconds a question waits; 0 makes #ask unavailable
      # @param sleeper [#call]
      def initialize(store:, events:, task_id:, timeout:, sleeper: ->(s) { sleep(s) })
        @store = store
        @events = events
        @task_id = task_id
        @timeout = timeout
        @sleeper = sleeper
        @notes = State::Notes.new(store.dir)
      end

      # @return [Proc, nil] the ask callback for the toolbox, or nil when asking is turned off
      def asker
        @timeout.positive? ? method(:ask).to_proc : nil
      end

      # @return [Proc] the inbox callback for the session
      def inbox
        method(:fresh).to_proc
      end

      # Notes the agent has not seen yet, marked as seen.
      # @return [Array<String>]
      def fresh
        notes = @notes.read(after: read_upto)
        return [] if notes.empty?

        @store.update_run({ "notesRead" => notes.last["seq"] })
        notes.each { |n| @events.emit(stage: "task.implement", kind: "accepted", task: @task_id, subject: "note from the user", detail: n["text"][0, 300]) }
        notes.map { |n| n["text"] }
      end

      # Put the agent's question to the user and wait for a note. The question is in run.json ("agentQuestion")
      # and in the events while it waits.
      # @param question [String]
      # @return [String] the answer, or what to do without one
      def ask(question)
        @store.update_run({ "agentQuestion" => { "task" => @task_id, "text" => question } })
        @events.emit(stage: "task.implement", kind: "question", task: @task_id, subject: "agent question", detail: question[0, 300])
        waited = 0.0
        while waited < @timeout
          answers = fresh
          return "The user answered: #{answers.join("\n")}" unless answers.empty?

          @sleeper.call(POLL)
          waited += POLL
        end
        wait = @timeout < 120 ? "#{@timeout} seconds" : "#{(@timeout / 60.0).round} minutes"
        "No answer came within #{wait}. Decide yourself, carefully, and say in finish what you assumed."
      ensure
        @store.update_run({ "agentQuestion" => nil })
      end

      private

      # @return [Integer]
      def read_upto = @store.read_run["notesRead"].to_i
    end
  end
end
