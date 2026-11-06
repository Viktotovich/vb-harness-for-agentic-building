# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../parse"

module Harness
  module Agent
    # A command the agent may run, declared in config (I3): fixed argv, where an argument that is exactly
    # "{name}" is filled from a declared parameter. The model chooses the command by name and gives parameter
    # values; it never supplies a command string.
    # params: name => "path" (a file in the repository) | "word" (letters, digits and . _ : / @ - only).
    Command = Data.define(:name, :description, :argv, :params, :timeout_sec)

    # The "agent" block of config.json. max_steps: tool calls per task; max_rounds: how often the harness may
    # send a task back after its own gates or review found a problem; max_files_per_task: replaces
    # maxFilesPerTask in agent mode; investigate: explore the repository before planning, within
    # max_investigate_steps; ask_timeout_sec: how long a task agent's question waits for the user's answer (0: the
    # agent cannot ask); max_recoveries: how many further tries a task gets when its agent stops without finishing
    # (see Ladder).
    Settings = Data.define(:max_steps, :max_rounds, :max_files_per_task, :investigate, :max_investigate_steps, :commands,
                           :ask_timeout_sec, :max_recoveries)

    # Parsing for Settings.
    class Settings
      KEYS = %w[maxSteps maxRounds maxFilesPerTask investigate maxInvestigateSteps commands askTimeoutSec maxRecoveries].freeze
      COMMAND_KEYS = %w[argv description params timeoutSec].freeze
      PARAM_KINDS = %w[path word].freeze
      NAME = /\A[a-z][a-z0-9_]{0,39}\z/

      # @return [Settings] the defaults
      def self.defaults = parse({})

      # @param raw [Hash]
      # @return [Settings]
      # @raise [ParseError]
      def self.parse(raw)
        h = Parse.hash!(raw, "agent")
        Parse.known_keys!(h, KEYS, "agent")
        new(max_steps: Parse.int!(h.fetch("maxSteps", 60), "agent.maxSteps", min: 1),
            max_rounds: Parse.int!(h.fetch("maxRounds", 6), "agent.maxRounds", min: 1),
            max_files_per_task: Parse.int!(h.fetch("maxFilesPerTask", 12), "agent.maxFilesPerTask", min: 1),
            investigate: Parse.bool!(h.fetch("investigate", true), "agent.investigate"),
            max_investigate_steps: Parse.int!(h.fetch("maxInvestigateSteps", 30), "agent.maxInvestigateSteps", min: 1),
            commands: Parse.hash!(h.fetch("commands", {}), "agent.commands").to_h { |name, c| [name, command(name, c)] }.freeze,
            ask_timeout_sec: Parse.int!(h.fetch("askTimeoutSec", 900), "agent.askTimeoutSec", min: 0),
            max_recoveries: Parse.int!(h.fetch("maxRecoveries", 3), "agent.maxRecoveries", min: 0))
      end

      # @return [Command]
      # @raise [ParseError]
      def self.command(name, raw)
        path = "agent.commands.#{name}"
        raise ParseError, "#{path}: a name of lowercase letters, digits and _" unless name.match?(NAME)

        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, COMMAND_KEYS, path)
        argv = Parse.strings!(h["argv"], "#{path}.argv")
        raise ParseError, "#{path}.argv: at least the program" if argv.empty?

        params = Parse.hash!(h.fetch("params", {}), "#{path}.params").to_h do |p, kind|
          raise ParseError, "#{path}.params.#{p}: a name of lowercase letters, digits and _" unless p.match?(NAME)

          [p, Parse.enum!(kind, "#{path}.params.#{p}", PARAM_KINDS)]
        end
        holes = argv.filter_map { |a| a[/\A\{([a-z][a-z0-9_]*)\}\z/, 1] }
        unknown = holes - params.keys
        raise ParseError, "#{path}.argv: {#{unknown.first}} is not declared in params" unless unknown.empty?
        if argv.first.include?("{")
          raise ParseError, "#{path}.argv: the program cannot be a parameter"
        end

        Command.new(name: name, description: Parse.str!(h.fetch("description", name), "#{path}.description"), argv: argv.freeze,
                    params: params.freeze, timeout_sec: Parse.int!(h.fetch("timeoutSec", 300), "#{path}.timeoutSec", min: 1))
      end
      private_class_method :command
    end
  end
end
