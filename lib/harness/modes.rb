# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "errors"

module Harness
  # Presets for how careful a run is, and which model the planner and reviewers use. Shared by `harness init` and
  # the app's Settings; both work on the raw config.json hash, and any value can still be edited there afterwards.
  module Modes
    # name => [label, what it means, the settings it writes]
    ALL = {
      "careful" => ["Careful", "review every task and the whole run, and stop when the repository's own checks " \
                               "already fail before the run", { "review" => "full", "requireGreenBaseline" => true, "maxFixRounds" => 3 }],
      "balanced" => ["Balanced", "skip the review of small tasks that pass their checks first time; the whole run " \
                                 "is still reviewed", { "review" => "light", "requireGreenBaseline" => false, "maxFixRounds" => 3 }],
      "quick" => ["Quick", "no review and fewer fix rounds, for trying things out",
                  { "review" => "off", "requireGreenBaseline" => false, "maxFixRounds" => 2 }]
    }.freeze
    DEFAULT = "balanced"
    # With a second model, these roles use it; the implementer, fixer and summarizer keep the first.
    SECOND_ROLES = %w[planner reviewer verifier].freeze
    # The profile a second model is written to when it has none of its own.
    SECOND = "planning"

    # @param cfg [Hash] a raw config
    # @return [String, nil] the mode whose settings cfg has, nil when it matches none
    def self.current(cfg)
      ALL.keys.find { |k| ALL[k][2].all? { |f, v| cfg[f] == v } }
    end

    # @param cfg [Hash] a raw config, changed in place
    # @param name [String] a key of ALL
    # @return [Hash] cfg
    # @raise [ParseError] for an unknown mode
    def self.apply(cfg, name)
      settings = ALL.dig(name.to_s, 2) or raise ParseError, "mode: expected one of #{ALL.keys.join(', ')}"
      cfg.merge!(settings)
    end

    # @param cfg [Hash] a raw config
    # @return [String, nil] the profile the planner uses when it is not the implementer's, else nil
    def self.second(cfg)
      roles = cfg["roles"] || {}
      planner = roles["planner"]
      planner && planner != roles.fetch("implementer", "default") ? planner : nil
    end

    # Points the planner, reviewer and verifier at a profile, or back at the implementer's with nil.
    # @param cfg [Hash] a raw config, changed in place
    # @param profile [String, nil]
    # @return [Hash] cfg
    # @raise [ParseError] when the profile is not configured
    def self.assign_second(cfg, profile)
      roles = cfg["roles"] ||= {}
      target = profile || roles.fetch("implementer", "default")
      raise ParseError, "no profile named #{target.to_s[0, 40].inspect}" unless cfg.fetch("profiles", {}).key?(target)

      SECOND_ROLES.each { |r| roles[r] = target }
      cfg
    end
  end
end
