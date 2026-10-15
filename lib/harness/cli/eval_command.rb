# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "optparse"
require_relative "../config"
require_relative "../errors"
require_relative "../eval/runner"
require_relative "commands"

module Harness
  module CLI
    # harness eval [--profile-map FILE] [--tasks GLOB]: run the eval tasks under each profile mapping and print a
    # markdown table per mapping (DESIGN.md 12). It needs a model server; run it by hand, never in CI.
    module EvalCommand
      USAGE = "Usage: harness eval [--profile-map FILE] [--tasks GLOB] [--out DIR] [--keep] [--config FILE] [--json]"
      ROOT = File.expand_path("../../../eval", __dir__)

      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @param env [Hash{String=>String}]
      # @param pipeline_for [#call, nil] (config, home) -> Pipeline; nil builds real model clients
      # @return [Integer] exit code: 0 when every task ran, 1 when one could not, 2 on a config problem
      def self.call(args, out:, err:, env:, pipeline_for: nil)
        opts = { config: "config.json", tasks: File.join(ROOT, "tasks", "*"), out: nil, keep: false, json: false }
        OptionParser.new do |o|
          o.banner = USAGE
          o.on("--config FILE", "Base config (default config.json)") { |v| opts[:config] = v }
          o.on("--profile-map FILE", "JSON: mapping name -> {roles, profiles} overrides") { |v| opts[:map] = v }
          o.on("--tasks GLOB", "Task folders (default eval/tasks/*)") { |v| opts[:tasks] = v }
          o.on("--out DIR", "Where runs go (default eval-out/ next to the config)") { |v| opts[:out] = v }
          o.on("--keep", "Keep worktrees for inspection") { opts[:keep] = true }
          o.on("--json", "Machine-readable output") { opts[:json] = true }
        end.parse(args)
        raw = read_json(opts[:config])
        Config.parse(raw, env: env)
        mappings = opts[:map] ? read_json(opts[:map]) : { "config" => {} }
        raise ParseError, "profile map: expected an object of mappings" unless mappings.is_a?(Hash) && !mappings.empty?

        home = File.dirname(File.expand_path(opts[:config]))
        out_dir = File.expand_path(opts[:out] || File.join(home, "eval-out"))
        pipeline_for ||= ->(config, dir) { Commands.pipeline_for(config, dir, env, err) }
        tasks = Eval::Runner.load_tasks(opts[:tasks], root: ROOT, env: env)
        raise ConfigError, "no eval tasks match #{opts[:tasks]}" if tasks.empty?

        results = Eval::Runner.new(raw_config: raw, env: env, out_dir: out_dir, pipeline_for: pipeline_for, keep: opts[:keep])
                              .call(mappings, tasks)
        if opts[:json]
          out.puts JSON.pretty_generate(results.transform_values { |scores| scores.map { |s| s.to_h.transform_keys(&:to_s) } })
        else
          out.puts Eval::Runner.table(results)
        end
        results.values.flatten.any? { |s| s.status == "error" } ? 1 : 0
      rescue ParseError, ConfigError => e
        err.puts "harness eval: #{e.message}"
        2
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
      private_class_method :read_json
    end
  end
end
