# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "optparse"
require_relative "../errors"
require_relative "../state/notes"
require_relative "../repo/worktree"
require_relative "../state/run_store"

module Harness
  module CLI
    # harness steer RUN_ID TEXT: a note to a running agent-mode run, from another terminal. The agent reads it
    # before its next turn; when it has asked a question, the note is the answer.
    module SteerCommand
      USAGE = "Usage: harness steer RUN_ID TEXT... [--config FILE]"

      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @return [Integer] 0, or 2 for a usage error or an unknown run
      def self.call(args, out:, err:)
        config = "config.json"
        rest = OptionParser.new do |o|
          o.banner = USAGE
          o.on("--config FILE", "Config file; runs/ lives next to it (default config.json)") { |v| config = v }
        end.parse(args)
        raise OptionParser::MissingArgument, "RUN_ID and TEXT" if rest.size < 2

        run_id = rest.first
        raise ConfigError, "run id #{run_id.inspect}: expected letters, digits, - or _" unless run_id.match?(Repo::Worktree::RUN_ID)

        store = State::RunStore.new(runs_dir: File.join(File.dirname(File.expand_path(config)), "runs"), run_id: run_id)
        raise ConfigError, "no run #{run_id}" unless store.exist?

        run = store.read_run
        seq = State::Notes.new(store.dir).add(rest.drop(1).join(" "))
        question = run["agentQuestion"]
        out.puts(if question.is_a?(Hash)
                   "note #{seq} answers the agent's question (#{question['task']}): #{question['text']}"
                 else
                   "note #{seq} added; the agent reads it before its next turn"
                 end)
        unless run["mode"] == "agent" && run["status"] == "running"
          err.puts "harness steer: run #{run_id} is #{run['status'] || 'not started'}#{run['mode'] == 'agent' ? '' : ' and not in agent mode'}; " \
                   "only a running agent-mode run reads notes"
        end
        0
      rescue ConfigError, ParseError => e
        err.puts "harness steer: #{e.message}"
        2
      end
    end
  end
end
