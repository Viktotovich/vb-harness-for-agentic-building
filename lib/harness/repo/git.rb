# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../exec"

module Harness
  module Repo
    # The only way the harness runs git: argv through Harness::Exec, checked against the allowlist in
    # DESIGN.md 9.2. Nothing here can push, fetch, merge or touch a remote (I4).
    class Git
      # Each rule: first words of the argv, and a check on the rest.
      ALLOWED = [
        [%w[worktree add], ->(rest) { rest.size == 4 && rest[0] == "-b" && rest[3] == "HEAD" }],
        [%w[worktree remove], ->(rest) { [1, 2].include?(rest.size) && (rest.size == 1 || rest[0] == "--force") }],
        [%w[status], ->(rest) { rest.all? { |a| a.start_with?("-") } }],
        [%w[diff], ->(_rest) { true }],
        [%w[add -A], ->(rest) { rest.empty? }],
        [%w[commit], ->(rest) { rest.size == 2 && rest[0] == "-m" }],
        [%w[checkout -- .], ->(rest) { rest.empty? }],
        [%w[clean -fd], ->(rest) { rest.empty? }],
        [%w[rev-parse], ->(_rest) { true }],
        [%w[log], ->(_rest) { true }]
      ].freeze
      # Remote-touching options that no allowed subcommand may carry.
      FORBIDDEN_ARGS = /\A--(?:exec|upload-pack|receive-pack|output|ext-diff|textconv)\b/

      # @param env [Hash{String=>String}] child environment (scrubbed, see Gates::Env)
      # @param timeout [Numeric] seconds per git command
      def initialize(env:, timeout: 120)
        @env = env
        @timeout = timeout
      end

      # @param args [Array<String>] git arguments, without "git"
      # @param chdir [String] repository or worktree directory
      # @param ok_codes [Array<Integer>] exit codes that count as success
      # @return [String] stdout
      # @raise [GitError] when the command is not allowed or fails
      def run(args, chdir:, ok_codes: [0])
        check!(args)
        r = Exec.run(["git", *args], chdir: chdir, env: @env, timeout: @timeout, max_output: 16 * 1024 * 1024)
        return r.stdout if ok_codes.include?(r.exit_code) && !r.timed_out

        raise GitError, "git #{args.first(2).join(' ')} failed (#{r.timed_out ? 'timeout' : "exit #{r.exit_code}"}): " \
                        "#{r.stderr.strip.lines.last(3).join.strip[0, 300]}"
      rescue CommandNotFoundError => e
        raise GitError, "git is not available: #{e.message}"
      end

      # @param args [Array<String>]
      # @return [Boolean]
      def self.allowed?(args)
        return false unless args.is_a?(Array) && args.all?(String)
        return false if args.any? { |a| a.match?(FORBIDDEN_ARGS) }

        ALLOWED.any? { |head, rest_ok| args.first(head.size) == head && rest_ok.call(args.drop(head.size)) }
      end

      private

      # @raise [GitError]
      def check!(args)
        raise GitError, "git command not allowed: #{args.first(3).inspect}" unless self.class.allowed?(args)
      end
    end
  end
end
