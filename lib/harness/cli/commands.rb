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
require_relative "../pipeline"
require_relative "../state/records"

module Harness
  module CLI
    # harness run / answer / resume. Progress goes to stderr, the result to stdout (or --json).
    module Commands
      USAGE = {
        "run" => "Usage: harness run --repo PATH (--request FILE | --from-plan FILE) [--plan-only] [--config FILE] [--json]",
        "answer" => "Usage: harness answer RUN_ID [--answers FILE] [--config FILE] [--json]",
        "resume" => "Usage: harness resume RUN_ID [--config FILE] [--json]"
      }.freeze

      # @param name [String] run, answer or resume
      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @param env [Hash{String=>String}]
      # @param input [IO] where answers are read when no --answers file is given
      # @return [Integer] exit code (DESIGN.md 5.5)
      def self.call(name, args, out:, err:, env:, input: $stdin)
        opts = parse(name, args)
        pipeline = pipeline(opts[:config], env, err)
        result = case name
                 when "run" then start(pipeline, opts)
                 when "answer" then pipeline.answer(opts[:run_id], answers(opts, pipeline.questions(opts[:run_id]), err, input))
                 else pipeline.resume(opts[:run_id])
                 end
        report(result, out, opts[:json])
      rescue ParseError, ConfigError, GitError, ModelUnavailableError, ModelOutputError, ContextOverflowError => e
        err.puts "harness #{name}: #{e.message}"
        e.is_a?(ModelOutputError) ? 1 : 2
      end

      # @return [Hash]
      # @raise [OptionParser::ParseError]
      def self.parse(name, args)
        opts = { config: "config.json", json: false, plan_only: false }
        parser = OptionParser.new do |o|
          o.banner = USAGE.fetch(name)
          o.on("--config FILE", "Config file (default config.json)") { |v| opts[:config] = v }
          o.on("--json", "Machine-readable output") { opts[:json] = true }
          if name == "run"
            o.on("--repo PATH", "Target git repository") { |v| opts[:repo] = v }
            o.on("--request FILE", "Feature request to plan") { |v| opts[:request] = v }
            o.on("--from-plan FILE", "Run a saved or hand-written plan") { |v| opts[:from_plan] = v }
            o.on("--plan-only", "Stop after planning, so the plan can be edited") { opts[:plan_only] = true }
          end
          o.on("--answers FILE", "JSON array of answers, one per question") { |v| opts[:answers] = v } if name == "answer"
        end
        rest = parser.parse(args)
        if name == "run"
          raise OptionParser::MissingArgument, "--repo" unless opts[:repo]
          raise OptionParser::InvalidArgument, "give exactly one of --request and --from-plan" if opts[:request].nil? == opts[:from_plan].nil?
        else
          raise OptionParser::MissingArgument, "RUN_ID" unless rest.size == 1

          opts[:run_id] = rest.first
        end
        opts
      end

      # @return [Pipeline]
      def self.pipeline(config_path, env, err)
        config = Config.load(config_path, env: env)
        pipeline_for(config, File.dirname(File.expand_path(config_path)), env, err)
      end

      # A pipeline whose runs, logs and caches live under home.
      # @param config [Config]
      # @param home [String]
      # @param env [Hash{String=>String}]
      # @param err [IO] progress lines
      # @return [Pipeline]
      def self.pipeline_for(config, home, env, err)
        http = Model::Http.new
        probe = Model::Probe.new(http: http, cache_dir: File.join(home, ".cache"), env: env)
        log = Log.new(dir: File.join(home, "logs"), echo: err)
        factory = lambda do |store|
          Model::Client.new(config: config, http: http, env: env, probe: probe, log: log,
                            records: State::Records.new(store.records_dir), run_id: store.run_id)
        end
        Pipeline.new(config: config, home: home, env: env, client_factory: factory)
      end

      # @return [Pipeline::Result]
      def self.start(pipeline, opts)
        if opts[:request]
          pipeline.start(repo: opts[:repo], request: read(opts[:request]), plan_only: opts[:plan_only])
        else
          pipeline.start(repo: opts[:repo], plan_hash: read_json(opts[:from_plan]), plan_only: opts[:plan_only])
        end
      end

      # @return [Array<String>]
      # @raise [ParseError]
      def self.answers(opts, questions, err, input)
        if opts[:answers]
          list = read_json(opts[:answers])
          Parse.strings!(list, "answers")
        else
          questions.map do |q|
            err.puts "Q: #{q}"
            err.print "A: " if err.respond_to?(:print)
            input.gets.to_s.strip
          end
        end
      end

      # @return [String]
      # @raise [ParseError]
      def self.read(path)
        File.read(path, encoding: "UTF-8")
      rescue Errno::ENOENT
        raise ParseError, "#{File.basename(path)}: file not found"
      end

      # @return [Object]
      # @raise [ParseError]
      def self.read_json(path)
        JSON.parse(read(path))
      rescue JSON::ParserError => e
        raise ParseError, "#{File.basename(path)}: not valid JSON (#{e.message.lines.first.strip})"
      end

      # @param result [Pipeline::Result]
      # @return [Integer] the exit code
      def self.report(result, out, json)
        if json
          out.puts JSON.pretty_generate(json_of(result))
          return result.exit_code
        end

        out.puts "run #{result.run_id}: #{result.status}"
        out.puts "  #{result.error}" if result.error
        result.questions.each_with_index { |q, i| out.puts "  question #{i + 1}: #{q}" }
        out.puts "  answer with: harness answer #{result.run_id}" unless result.questions.empty?
        result.issues.each { |i| out.puts "  plan problem: #{i.message}" }
        out.puts "  plan: #{result.plan_path}" if %w[planned plan_rejected].include?(result.status)
        if result.outcome
          out.puts "  branch: #{result.outcome.branch}"
          result.outcome.tasks.each do |t|
            extra = t.status == "done" ? (t.commit ? "commit #{t.commit[0, 7]}" : "no changes") : (t.reason || t.detail)
            out.puts format("  %<id>-6s %<status>-8s %<extra>s (fix rounds: %<n>d)", id: t.id, status: t.status, extra: extra, n: t.fix_rounds)
          end
          result.outcome.integration.each { |c| out.puts "  integration #{c.gate}: #{c.verdict}" }
        end
        result.exit_code
      end

      # @return [Hash]
      def self.json_of(result)
        h = { "run" => result.run_id, "status" => result.status, "exitCode" => result.exit_code,
              "questions" => result.questions, "issues" => result.issues.map { |i| i.to_h.transform_keys(&:to_s) },
              "plan" => result.plan_path, "error" => result.error }
        return h unless result.outcome

        h.merge("branch" => result.outcome.branch,
                "tasks" => result.outcome.tasks.map { |t| t.to_h.transform_keys(&:to_s) },
                "integration" => result.outcome.integration.map { |c| { "gate" => c.gate, "verdict" => c.verdict } })
      end
      private_class_method :parse, :pipeline, :start, :answers, :read, :read_json, :report, :json_of
    end
  end
end
