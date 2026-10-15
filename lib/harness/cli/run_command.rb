# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "optparse"
require_relative "../config"
require_relative "../errors"
require_relative "../log"
require_relative "../model/client"
require_relative "../model/http"
require_relative "../model/probe"
require_relative "../plan/plan"
require_relative "../run"
require_relative "../state/records"
require_relative "../state/run_store"

module Harness
  module CLI
    # harness run --repo PATH (--from-plan FILE | --request FILE) [--config FILE] [--json]
    module RunCommand
      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @param env [Hash{String=>String}]
      # @return [Integer] exit code (DESIGN.md 5.5)
      def self.call(args, out:, err:, env:)
        opts = parse(args)
        unless opts[:from_plan]
          err.puts "harness run: planning from --request arrives with the planner; for now pass --from-plan FILE"
          return 2
        end

        config = Config.load(opts[:config], env: env)
        home = File.dirname(File.expand_path(opts[:config]))
        plan = Plan::PlanParser.parse(read_json(opts[:from_plan]))
        store = State::RunStore.new(runs_dir: File.join(home, "runs"), run_id: State::RunStore.new_run_id)
        client = build_client(config, home, store, env, err)
        setup = Run.intake(config: config, repo: opts[:repo], store: store, parent_env: env)
        report(Run.new(config: config, client: client, setup: setup).execute(plan), out, opts[:json])
      rescue ParseError, ConfigError, GitError, ModelUnavailableError => e
        err.puts "harness run: #{e.message}"
        2
      end

      # @return [Hash]
      # @raise [OptionParser::ParseError]
      def self.parse(args)
        opts = { config: "config.json", json: false }
        OptionParser.new do |o|
          o.banner = "Usage: harness run --repo PATH (--from-plan FILE | --request FILE) [options]"
          o.on("--repo PATH", "Target git repository") { |v| opts[:repo] = v }
          o.on("--request FILE", "Feature request (needs the planner)") { |v| opts[:request] = v }
          o.on("--from-plan FILE", "Run a saved or hand-written plan") { |v| opts[:from_plan] = v }
          o.on("--config FILE", "Config file (default config.json)") { |v| opts[:config] = v }
          o.on("--json", "Machine-readable output") { opts[:json] = true }
        end.parse!(args)
        raise OptionParser::MissingArgument, "--repo" unless opts[:repo]

        opts
      end

      # @return [Model::Client]
      def self.build_client(config, home, store, env, err)
        http = Model::Http.new
        Model::Client.new(config: config, http: http, env: env,
                          probe: Model::Probe.new(http: http, cache_dir: File.join(home, ".cache"), env: env),
                          records: State::Records.new(store.records_dir),
                          log: Log.new(dir: File.join(home, "logs"), echo: err))
      end

      # @return [Object]
      # @raise [ParseError]
      def self.read_json(path)
        JSON.parse(File.read(path, encoding: "UTF-8"))
      rescue Errno::ENOENT
        raise ParseError, "#{File.basename(path)}: file not found"
      rescue JSON::ParserError => e
        raise ParseError, "#{File.basename(path)}: not valid JSON (#{e.message.lines.first.strip})"
      end

      # @param outcome [Run::Outcome]
      # @return [Integer] the exit code
      def self.report(outcome, out, json)
        if json
          out.puts JSON.pretty_generate({ "run" => outcome.run_id, "branch" => outcome.branch, "exitCode" => outcome.exit_code,
                                          "tasks" => outcome.tasks.map { |t| t.to_h.transform_keys(&:to_s) },
                                          "integration" => outcome.integration.map { |c| { "gate" => c.gate, "verdict" => c.verdict } } })
        else
          out.puts "run #{outcome.run_id} on branch #{outcome.branch}"
          outcome.tasks.each do |t|
            extra = t.status == "done" ? (t.commit ? "commit #{t.commit[0, 7]}" : "no changes") : (t.reason || t.detail)
            out.puts format("  %<id>-6s %<status>-8s %<extra>s (fix rounds: %<rounds>d)", id: t.id, status: t.status, extra: extra, rounds: t.fix_rounds)
          end
          outcome.integration.each { |c| out.puts "  integration #{c.gate}: #{c.verdict}" }
        end
        outcome.exit_code
      end
      private_class_method :parse, :build_client, :read_json, :report
    end
  end
end
