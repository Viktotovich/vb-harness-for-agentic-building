# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  module Agent
    # The tries a task gets after its agent stops without finishing. Trying again the same way mostly fails the same
    # way, so each rung changes something: a clean conversation, then a smaller job with the checks' current verdict,
    # then a stronger model when one is configured. The ladder is short on purpose: when it runs out the task blocks.
    class Ladder
      # name: for events and the report; role: the model role that takes the try; checks: run the task's checks first
      # and give the agent their verdict; share: the part of agent.maxSteps it gets.
      Rung = Data.define(:name, :role, :checks, :share)

      FRESH = Rung.new(name: "fresh start", role: :implementer, checks: false, share: 1.0)
      NARROW = Rung.new(name: "narrower task", role: :implementer, checks: true, share: 0.5)
      STRONGER = Rung.new(name: "stronger model", role: :rescuer, checks: true, share: 1.0)

      # @return [Array<String>] the names of the rungs taken so far
      attr_reader :used

      # @param max [Integer] agent.maxRecoveries
      # @param stronger [Boolean] whether the rescuer role is a different profile from the implementer
      def initialize(max:, stronger:)
        @rungs = [FRESH, NARROW, *(stronger ? [STRONGER] : [])].first(max)
        @used = []
      end

      # @return [Rung, nil] the next try, or nil when none is left
      def next
        rung = @rungs.shift
        @used << rung.name if rung
        rung
      end
    end
  end
end
