# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "optparse"
require_relative "../errors"
require_relative "../report/render"
require_relative "../report/status"
require_relative "../state/run_store"

module Harness
  module CLI
    # harness status [RUN_ID] [--watch] and harness report RUN_ID: read-only views of a run's files.
    module Inspect
      USAGE = {
        "status" => "Usage: harness status [RUN_ID] [--watch] [--config FILE] [--json]",
        "report" => "Usage: harness report RUN_ID [--config FILE] [--json]"
      }.freeze

      # @param name [String] status or report
      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @param sleeper [#call] waits between --watch refreshes
      # @return [Integer] exit code
      def self.call(name, args, out:, err:, sleeper: ->(s) { sleep(s) })
        opts = { config: "config.json", json: false, watch: false }
        rest = OptionParser.new do |o|
          o.banner = USAGE.fetch(name)
          o.on("--config FILE", "Config file; runs/ lives next to it (default config.json)") { |v| opts[:config] = v }
          o.on("--json", "Machine-readable output") { opts[:json] = true }
          o.on("--watch", "Refresh every second until the run stops") { opts[:watch] = true } if name == "status"
        end.parse(args)
        raise OptionParser::MissingArgument, "RUN_ID" if name == "report" && rest.size != 1

        store = store_for(opts[:config], rest.first)
        name == "report" ? report(store, out, opts[:json]) : status(store, out, opts, sleeper)
      rescue ConfigError => e
        err.puts "harness #{name}: #{e.message}"
        2
      end

      # The named run, or the newest one.
      # @return [State::RunStore]
      # @raise [ConfigError]
      def self.store_for(config_path, run_id)
        runs = File.join(File.dirname(File.expand_path(config_path)), "runs")
        run_id ||= Dir.children(runs).select { |d| File.file?(File.join(runs, d, "run.json")) }.max if File.directory?(runs)
        raise ConfigError, "no runs in #{runs}" unless run_id

        store = State::RunStore.new(runs_dir: runs, run_id: run_id)
        raise ConfigError, "no run #{run_id}" unless store.exist?

        store
      end

      # @return [Integer]
      def self.report(store, out, json)
        path = Report::Render.write(store)
        out.puts(json ? JSON.pretty_generate({ "run" => store.run_id, "report" => path }) : path)
        0
      end

      # @return [Integer]
      def self.status(store, out, opts, sleeper)
        if opts[:json]
          out.puts JSON.pretty_generate(Report::Status.json(store))
          return 0
        end
        loop do
          out.print "\e[H\e[2J" if opts[:watch]
          out.puts Report::Status.render(store)
          break if !opts[:watch] || Report::Status.finished?(store)

          sleeper.call(1)
        end
        0
      end
      private_class_method :store_for, :report, :status
    end
  end
end
