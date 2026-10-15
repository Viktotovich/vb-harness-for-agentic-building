# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require_relative "../errors"
require_relative "git"
require_relative "paths"

module Harness
  module Repo
    # The run's own git worktree on branch harness/<runId>. The user's checkout is never modified (I11):
    # every write and every commit happens here.
    class Worktree
      RUN_ID = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/

      # @return [String] the user's repository (top level)
      attr_reader :repo
      # @return [String] the worktree directory (real path)
      attr_reader :root
      # @return [String] e.g. "harness/r7"
      attr_reader :branch
      # @return [String] HEAD of the repository when the run started
      attr_reader :base_sha

      # Create <repo>/../.harness-worktrees/<runId> on a new branch harness/<runId> from HEAD.
      # @param repo [String] path inside the user's repository
      # @param run_id [String]
      # @param git [Git]
      # @return [Worktree]
      # @raise [GitError] when repo is not a git repository, has uncommitted changes, or the worktree exists
      # @raise [ArgumentError] on a malformed run id
      def self.create(repo:, run_id:, git:)
        raise ArgumentError, "run id #{run_id.inspect}: expected letters, digits, - or _" unless run_id.to_s.match?(RUN_ID)

        top = top_level(repo, git)
        dirty = git.run(%w[status --porcelain --untracked-files=all], chdir: top)
        raise GitError, "the repository has uncommitted changes; commit or stash them first" unless dirty.strip.empty?

        base = git.run(%w[rev-parse HEAD], chdir: top).strip
        dir = File.join(File.dirname(top), ".harness-worktrees", run_id)
        raise GitError, "worktree for run #{run_id} already exists" if File.exist?(dir)

        branch = "harness/#{run_id}"
        git.run(["worktree", "add", "-b", branch, dir, "HEAD"], chdir: top)
        new(repo: top, root: File.realpath(dir), branch: branch, base_sha: base, git: git)
      end

      # @return [String]
      # @raise [GitError]
      def self.top_level(repo, git)
        raise GitError, "#{File.basename(repo.to_s)}: not a directory" unless File.directory?(repo.to_s)

        git.run(%w[rev-parse --show-toplevel], chdir: repo).strip
      rescue GitError => e
        raise GitError, "not a git repository (#{e.message})"
      end
      private_class_method :top_level

      # Reattach to an existing worktree (resume).
      # @param repo [String]
      # @param root [String]
      # @param branch [String]
      # @param base_sha [String]
      # @param git [Git]
      def initialize(repo:, root:, branch:, base_sha:, git:)
        @repo = repo
        @root = root
        @branch = branch
        @base_sha = base_sha
        @git = git
      end

      # @return [String] current HEAD sha of the worktree
      # @raise [GitError]
      def head
        @git.run(%w[rev-parse HEAD], chdir: @root).strip
      end

      # @return [String] subject line of the last commit
      # @raise [GitError]
      def head_subject
        @git.run(%w[log -1 --format=%s], chdir: @root).strip
      end

      # @return [Boolean] true when the worktree has uncommitted changes or untracked files
      # @raise [GitError]
      def dirty?
        !@git.run(%w[status --porcelain --untracked-files=all], chdir: @root).strip.empty?
      end

      # Stage everything in the worktree and commit.
      # @param message [String]
      # @return [String] the new commit sha
      # @raise [GitError] also when there is nothing to commit
      def commit(message)
        @git.run(%w[add -A], chdir: @root)
        @git.run(["commit", "--no-verify", "-m", message], chdir: @root)
        head
      end

      # Put the worktree back to its last commit: tracked files restored, untracked files removed,
      # and the given created files deleted even when .gitignore hides them from git clean.
      # @param created [Array<String>] relative paths the task created
      # @return [void]
      # @raise [GitError]
      def revert!(created: [])
        @git.run(%w[checkout -- .], chdir: @root)
        @git.run(%w[clean -fd], chdir: @root)
        created.each do |rel|
          full = Paths.resolve_in_worktree(@root, rel)
          FileUtils.rm_f(full) if File.file?(full)
        end
      end

      # Uncommitted changes as a patch: tracked changes plus untracked files as new-file diffs.
      # @param context [Integer] lines of context around each change
      # @return [String]
      # @raise [GitError]
      def patch(context: 3)
        tracked = @git.run(["diff", "-U#{context.to_i}", "HEAD"], chdir: @root)
        untracked = @git.run(%w[status --porcelain -z --untracked-files=all], chdir: @root)
                        .split("\0").select { |e| e.start_with?("?? ") }.map { |e| e[3..] }
        added = untracked.map do |rel|
          @git.run(["diff", "--no-index", "-U#{context.to_i}", "--", "/dev/null", rel], chdir: @root, ok_codes: [0, 1])
        end
        ([tracked] + added).reject(&:empty?).join
      end

      # Everything the run committed, from the base commit to HEAD.
      # @param context [Integer]
      # @return [String]
      # @raise [GitError]
      def range_patch(context: 3)
        @git.run(["diff", "-U#{context.to_i}", "#{@base_sha}..HEAD"], chdir: @root)
      end

      # Remove the worktree directory (the branch and its commits stay).
      # @param force [Boolean] also when it has uncommitted changes
      # @return [void]
      # @raise [GitError]
      def remove(force: false)
        @git.run(["worktree", "remove", *(force ? ["--force"] : []), @root], chdir: @repo)
      end
    end
  end
end
