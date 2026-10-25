# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "optparse"
require_relative "../demo"
require_relative "commands"

module Harness
  module CLI
    # harness demo: a whole run on a bundled project with a scripted model, so the harness can be seen working
    # before any model is set up. It lives in demo/ next to the config and touches nothing else.
    module DemoCommand
      USAGE = "Usage: harness demo [--config FILE] [--json]"

      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @param env [Hash{String=>String}]
      # @return [Integer] the run's exit code
      def self.call(args, out:, err:, env:)
        opts = { config: "config.json", json: false }
        OptionParser.new do |o|
          o.banner = USAGE
          o.on("--config FILE", "The demo lives in demo/ next to this file (default config.json)") { |v| opts[:config] = v }
          o.on("--json", "Machine-readable output") { opts[:json] = true }
        end.parse(args)
        dir = File.join(File.dirname(File.expand_path(opts[:config])), "demo")
        server = Demo::Server.new
        begin
          site, config = Demo.prepare(dir, server.base_url, env)
          err.puts "harness demo: a scripted model builds a request in #{site}; no real model runs."
          pipeline = Commands.pipeline_for(config, dir, Demo.git_env(env), err)
          result = pipeline.start(repo: site, request: Demo::REQUEST)
        ensure
          server.stop
        end
        Demo.mark(dir, result.run_id)
        report = File.join(dir, "runs", result.run_id, "report.md")
        if opts[:json]
          out.puts JSON.pretty_generate({ "run" => result.run_id, "status" => result.status, "exitCode" => result.exit_code,
                                          "project" => site, "report" => report })
        else
          out.puts "demo run #{result.run_id}: #{result.status}"
          result.outcome&.tasks&.each { |t| out.puts format("  %<id>-4s %<status>-8s fix rounds: %<n>d", id: t.id, status: t.status, n: t.fix_rounds) }
          out.puts "  report: #{report}"
          out.puts "  project: #{site} (branch #{result.outcome&.branch})"
          out.puts "Next: connect a real model with `harness` (the app) or `harness init`, then `harness doctor --repo PATH`."
        end
        result.exit_code
      end
    end
  end
end
