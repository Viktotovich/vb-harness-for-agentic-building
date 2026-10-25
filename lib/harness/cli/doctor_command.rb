# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "optparse"
require_relative "../doctor"

module Harness
  module CLI
    # harness doctor [--repo PATH]: every reason a run would not start, in one list, each with what to do.
    module DoctorCommand
      USAGE = "Usage: harness doctor [--repo PATH] [--config FILE] [--json]"

      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @param env [Hash{String=>String}]
      # @param doctor [#call, nil] (config_path, repo) -> Doctor, for tests
      # @return [Integer] 0 ready, 2 at least one problem
      def self.call(args, out:, err:, env:, doctor: nil)
        opts = { config: "config.json", json: false }
        OptionParser.new do |o|
          o.banner = USAGE
          o.on("--repo PATH", "Also check this repository: git, a clean tree, its stack, dependencies and gate tools") { |v| opts[:repo] = v }
          o.on("--config FILE", "Config file (default config.json)") { |v| opts[:config] = v }
          o.on("--json", "Machine-readable output") { opts[:json] = true }
        end.parse(args)
        doc = doctor ? doctor.call(opts[:config], opts[:repo]) : Doctor.new(config_path: opts[:config], env: env, repo: opts[:repo])
        checks = doc.checks
        ready = Doctor.ready?(checks)
        if opts[:json]
          out.puts JSON.pretty_generate({ "ready" => ready, "checks" => checks.map(&:to_json_hash) })
        else
          print_checks(checks, ready, opts[:repo], out)
        end
        ready ? 0 : 2
      end

      # @return [void]
      def self.print_checks(checks, ready, repo, out)
        checks.each do |c|
          out.puts format("  %<mark>-4s  %<area>-10s %<detail>s", mark: c.ok ? "ok" : "FIX", area: c.area, detail: c.detail)
          out.puts "              -> #{c.fix}" if c.fix && !c.ok
        end
        problems = checks.count { |c| !c.ok }
        out.puts(if ready
                   "Ready#{repo ? '' : ' (give --repo PATH to check a repository too)'}. Model output itself is only " \
                     "tested by a run."
                 else
                   "Not ready: #{problems} problem#{problems == 1 ? '' : 's'} to fix."
                 end)
      end
      private_class_method :print_checks
    end
  end
end
