# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "tmpdir"
require_relative "../errors"
require_relative "../exec"

module Harness
  module Repo
    # The only way the harness runs git: argv through Harness::Exec, checked against the allowlist in
    # DESIGN.md 9.2. Nothing here can push, fetch, pull, merge or write to a remote (I4); the one download is the
    # confirmed shallow clone of a new project.
    class Git
      # Each rule: first words of the argv, and a check on the rest.
      ALLOWED = [
        [%w[worktree add], ->(rest) { rest.size == 4 && rest[0] == "-b" && rest[3] == "HEAD" }],
        [%w[worktree remove], ->(rest) { [1, 2].include?(rest.size) && (rest.size == 1 || rest[0] == "--force") }],
        [%w[status], ->(rest) { rest.all? { |a| a.start_with?("-") } }],
        [%w[diff], ->(_rest) { true }],
        [%w[add -A], ->(rest) { rest.empty? }],
        [%w[commit --no-verify], ->(rest) { rest.size == 2 && rest[0] == "-m" }],
        [%w[checkout -- .], ->(rest) { rest.empty? }],
        [%w[clean -fd], ->(rest) { rest.empty? }],
        [%w[rev-parse], ->(_rest) { true }],
        [%w[log], ->(_rest) { true }],
        # For the app's project picker (docs/decisions.md): a shallow https clone into projects/<name> (a download,
        # after the user confirms it), and a new repository for a new project. Nothing here writes to a remote.
        [%w[clone --depth 1 --], ->(rest) { rest.size == 2 && rest[0].match?(CLONE_URL) && rest[1].match?(CLONE_DEST) }],
        [%w[init -q -b main], ->(rest) { rest.empty? }]
      ].freeze
      CLONE_URL = %r{\Ahttps://[A-Za-z0-9.-]+(?::\d{1,5})?/[A-Za-z0-9._~%/+-]+\z}
      CLONE_DEST = %r{\Aprojects/[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z}
      # Remote-touching options that no allowed subcommand may carry.
      FORBIDDEN_ARGS = /\A--(?:exec|upload-pack|receive-pack|output|ext-diff|textconv)\b/

      # @param env [Hash{String=>String}] child environment (scrubbed, see Gates::Env)
      # @param timeout [Numeric] seconds per git command
      # @param cache_dir [String, nil] .cache/, which holds the empty hooks directory; nil uses the system temp dir
      def initialize(env:, timeout: 120, cache_dir: nil)
        @env = env
        @timeout = timeout
        @hooks_dir = File.join(cache_dir || File.join(Dir.tmpdir, "vb-harness"), "no-hooks")
      end

      # @param args [Array<String>] git arguments, without "git"
      # @param chdir [String] repository or worktree directory
      # @param ok_codes [Array<Integer>] exit codes that count as success
      # @return [String] stdout
      # @raise [GitError] when the command is not allowed or fails
      def run(args, chdir:, ok_codes: [0])
        check!(args)
        r = Exec.run(["git", "-c", "core.hooksPath=#{empty_hooks_dir}", *args], chdir: chdir, env: @env, timeout: @timeout, max_output: 16 * 1024 * 1024)
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

      # Every git command runs with hooks pointed at an empty directory: a repository's hooks (or ones a model
      # wrote, such as .husky/pre-commit) never run (I3). Commits also pass --no-verify.
      # @return [String]
      # @raise [GitError] when the directory is not empty
      def empty_hooks_dir
        FileUtils.mkdir_p(@hooks_dir)
        raise GitError, "#{@hooks_dir} must be empty: it disables git hooks" unless Dir.empty?(@hooks_dir)

        @hooks_dir
      end

      # @raise [GitError]
      def check!(args)
        raise GitError, "git command not allowed: #{args.first(3).inspect}" unless self.class.allowed?(args)
      end
    end
  end
end
