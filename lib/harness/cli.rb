# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "optparse"
require_relative "cli/commands"
require_relative "cli/eval_command"
require_relative "cli/init"
require_relative "cli/inspect"

module Harness
  # Command-line entry point. Subcommands arrive milestone by milestone (DESIGN.md section 11.1).
  module CLI
    SUBCOMMANDS = %w[init probe run status resume answer report eval cleanup push ui].freeze

    EXIT_OK = 0
    EXIT_CONFIG = 2

    # @param argv [Array<String>] command-line arguments
    # @param out [IO] stream for results
    # @param err [IO] stream for progress and errors
    # @param env [Hash{String=>String}] the process environment
    # @param input [IO] standard input, for interactive answers
    # @return [Integer] process exit code
    def self.run(argv, out: $stdout, err: $stderr, env: ENV, input: $stdin)
      args = argv.dup
      parser = global_parser(out)
      parser.order!(args)
      return EXIT_OK if args.empty? && parser_handled?(argv)

      name = args.shift || "ui"
      unless SUBCOMMANDS.include?(name)
        err.puts "harness: unknown command #{name.inspect}"
        err.puts parser.help
        return EXIT_CONFIG
      end
      case name
      when "run", "answer", "resume" then Commands.call(name, args, out: out, err: err, env: env, input: input)
      when "status", "report" then Inspect.call(name, args, out: out, err: err)
      when "eval" then EvalCommand.call(args, out: out, err: err, env: env)
      when "init" then init(args, out: out, err: err, env: env, input: input)
      else
        err.puts "harness: #{name} is not implemented yet"
        EXIT_CONFIG
      end
    rescue OptionParser::ParseError => e
      err.puts "harness: #{e.message}"
      EXIT_CONFIG
    end

    # @return [Integer]
    def self.init(args, out:, err:, env:, input:)
      path = "config.json"
      OptionParser.new do |o|
        o.banner = "Usage: harness init [--config FILE]"
        o.on("--config FILE", "Where to write the config (default config.json)") { |v| path = v }
      end.parse(args)
      Init.new(input: input, out: out, path: path, env: env).call
    rescue Init::Cancelled, ParseError => e
      err.puts "harness init: #{e.message}"
      EXIT_CONFIG
    end
    private_class_method :init

    # @param out [IO]
    # @return [OptionParser]
    def self.global_parser(out)
      OptionParser.new do |o|
        o.banner = "Usage: harness [--version] [--help] <command> [options]"
        o.separator ""
        o.separator "Commands: #{SUBCOMMANDS.join(', ')}"
        o.on("--version", "Print the version") { out.puts VERSION }
        o.on("-h", "--help", "Show this help") { out.puts o.help }
      end
    end
    private_class_method :global_parser

    # @param argv [Array<String>]
    # @return [Boolean] true when a global flag already produced the output
    def self.parser_handled?(argv)
      argv.any? { |a| %w[--version -h --help].include?(a) }
    end
    private_class_method :parser_handled?
  end
end
