# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../parse"

module Harness
  module Gates
    PARSERS = %w[astro_check tsc eslint vitest playwright].freeze
    SCOPES = %w[touched project tests].freeze
    PLACEHOLDERS = %w[{files} {tests}].freeze

    # One problem reported by a gate. file is relative to the worktree with "/" separators, or nil.
    Diagnostic = Data.define(:file, :line, :col, :code, :message, :severity) do
      # Identity for baseline comparison: same file, rule or code, and message (line numbers move).
      # @return [Array]
      def key
        [file, code, message]
      end
    end

    # A configured check (DESIGN.md 6). phase is config "when": "task" or "integration".
    Gate = Data.define(:name, :argv, :scope, :parser, :blocking, :cost_rank, :phase, :timeout_sec)

    # Parsing for Gate.
    class Gate
      KEYS = %w[argv scope parser blocking costRank when timeoutSec].freeze
      # A gate checks; it never installs (I10) or touches a remote (I4). Installs need the user's approval.
      PACKAGE_MANAGERS = %w[npm pnpm yarn bun].freeze
      INSTALL_WORDS = %w[install i add ci update upgrade up dlx].freeze
      AUTO_INSTALL = %w[--yes -y].freeze
      NEVER = %w[git gh].freeze

      # @param name [String]
      # @param raw [Hash]
      # @param path [String] location for error messages
      # @return [Gate]
      # @raise [ParseError]
      def self.parse(name, raw, path)
        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, KEYS, path)
        argv = Parse.strings!(h["argv"], "#{path}.argv")
        Parse.fail!("#{path}.argv", "non-empty argv array", argv) if argv.empty? || argv[0].strip.empty?
        argv.each_with_index do |a, i|
          next if PLACEHOLDERS.include?(a) || !a.match?(/\{(?:files|tests)\}/)

          raise ParseError, "#{path}.argv[#{i}]: {files} and {tests} must be whole arguments, got #{a.inspect}"
        end
        refuse_side_effects!(argv, path)
        parser = h["parser"]
        Parse.enum!(parser, "#{path}.parser", PARSERS) unless parser.nil?
        new(name: name, argv: argv.dup.freeze, scope: Parse.enum!(h.fetch("scope", "project"), "#{path}.scope", SCOPES),
            parser: parser, blocking: Parse.bool!(h.fetch("blocking", true), "#{path}.blocking"),
            cost_rank: Parse.int!(h.fetch("costRank", 5), "#{path}.costRank", min: 0),
            phase: Parse.enum!(h.fetch("when", "task"), "#{path}.when", %w[task integration]),
            timeout_sec: Parse.int!(h.fetch("timeoutSec", 600), "#{path}.timeoutSec", min: 1))
      end

      # @return [void]
      # @raise [ParseError] for a gate that would install packages, run git or gh, or let npx install on its own
      def self.refuse_side_effects!(argv, path)
        tool = File.basename(argv[0], ".*").downcase
        raise ParseError, "#{path}.argv: a gate may not run #{tool} (no git or remote calls, I4)" if NEVER.include?(tool)
        if PACKAGE_MANAGERS.include?(tool) && argv[1..].any? { |a| INSTALL_WORDS.include?(a) }
          raise ParseError, "#{path}.argv: a gate may not install packages (I10); install them yourself first"
        end
        return unless %w[npx pnpx bunx].include?(tool) && argv[1..].any? { |a| AUTO_INSTALL.include?(a) }

        raise ParseError, "#{path}.argv: #{argv[0]} with --yes installs missing packages (I10)"
      end
      private_class_method :refuse_side_effects!
    end

    # A stack profile from config "stacks" (DESIGN.md 6). framework and docs stay raw until the evidence port.
    Stack = Data.define(:name, :detect, :framework, :docs, :package_manager, :gates, :always_gates, :protected_paths)

    # Parsing for Stack.
    class Stack
      KEYS = %w[detect framework docs packageManager gates alwaysGates protectedPaths].freeze

      # @param name [String]
      # @param raw [Hash]
      # @return [Stack]
      # @raise [ParseError]
      def self.parse(name, raw)
        path = "stacks.#{name}"
        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, KEYS, path)
        gates = Parse.hash!(h.fetch("gates", {}), "#{path}.gates").to_h do |g, spec|
          [g, Gate.parse(g, spec, "#{path}.gates.#{g}")]
        end
        always = Parse.strings!(h.fetch("alwaysGates", []), "#{path}.alwaysGates")
        always.each do |g|
          raise ParseError, "#{path}.alwaysGates: no gate named #{g.inspect}" unless gates.key?(g)
        end
        new(name: name, detect: Parse.strings!(h.fetch("detect", []), "#{path}.detect").dup.freeze,
            framework: Parse.hash!(h.fetch("framework", {}), "#{path}.framework"),
            docs: Parse.hash!(h.fetch("docs", {}), "#{path}.docs"),
            package_manager: Parse.enum!(h.fetch("packageManager", "auto"), "#{path}.packageManager", %w[auto npm pnpm yarn]),
            gates: gates.freeze, always_gates: always.dup.freeze,
            protected_paths: Parse.strings!(h.fetch("protectedPaths", []), "#{path}.protectedPaths").dup.freeze)
      end
    end
  end
end
