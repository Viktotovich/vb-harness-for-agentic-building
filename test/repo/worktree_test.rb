# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

class WorktreeTest < Minitest::Test
  Git = Harness::Repo::Git
  Worktree = Harness::Repo::Worktree

  def setup
    @tmp = Dir.mktmpdir("harness-wt-")
    @repo, @env = TestSupport.repo(@tmp, { "README.md" => "# fixture\n", "src/a.ts" => "export const a = 1;\n",
                                           ".gitignore" => "dist/\n" })
    @git = Git.new(env: @env)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def create(run_id = "r1")
    Worktree.create(repo: @repo, run_id: run_id, git: @git)
  end

  def repo_head
    TestSupport.git!(@repo, @env, "rev-parse", "HEAD").strip
  end

  def test_create_makes_a_branch_in_a_sibling_directory
    wt = create
    assert_equal "harness/r1", wt.branch
    assert File.identical?(File.join(@tmp, ".harness-worktrees", "r1"), wt.root), wt.root
    assert_equal repo_head, wt.base_sha
    assert_equal "export const a = 1;\n", File.read(File.join(wt.root, "src/a.ts"))
    refute wt.dirty?
  end

  def test_refuses_a_dirty_repository
    File.write(File.join(@repo, "notes.txt"), "untracked")
    err = assert_raises(Harness::GitError) { create }
    assert_match(/uncommitted changes/, err.message)
  end

  def test_refuses_a_directory_that_is_not_a_repository
    plain = File.join(@tmp, "plain")
    FileUtils.mkdir_p(plain)
    assert_raises(Harness::GitError) { Worktree.create(repo: plain, run_id: "r1", git: @git) }
  end

  def test_refuses_malformed_run_ids
    ["../x", "a b", "", "-x", "a/b"].each do |id|
      assert_raises(ArgumentError, id.inspect) { create(id) }
    end
  end

  def test_commit_stays_on_the_run_branch
    wt = create
    File.write(File.join(wt.root, "src/b.ts"), "export const b = 2;\n")
    sha = wt.commit("T1: add b\n\nGates passed: lint")
    assert_equal sha, wt.head
    refute_equal wt.base_sha, sha
    assert_equal wt.base_sha, repo_head, "the user's branch did not move"
    refute File.exist?(File.join(@repo, "src/b.ts")), "the user's checkout was not touched"
  end

  def test_revert_restores_the_last_commit_including_ignored_created_files
    wt = create
    File.write(File.join(wt.root, "src/a.ts"), "changed")
    File.delete(File.join(wt.root, "README.md"))
    FileUtils.mkdir_p(File.join(wt.root, "src/new"))
    File.write(File.join(wt.root, "src/new/c.ts"), "new")
    FileUtils.mkdir_p(File.join(wt.root, "dist"))
    File.write(File.join(wt.root, "dist/out.js"), "ignored but created by the task")
    wt.revert!(created: ["dist/out.js"])
    assert_equal "export const a = 1;\n", File.read(File.join(wt.root, "src/a.ts"))
    assert File.exist?(File.join(wt.root, "README.md"))
    refute File.exist?(File.join(wt.root, "src/new/c.ts"))
    refute File.exist?(File.join(wt.root, "dist/out.js"))
    refute wt.dirty?
  end

  def test_patch_contains_tracked_changes_and_new_files
    wt = create
    File.write(File.join(wt.root, "src/a.ts"), "export const a = 2;\n")
    File.write(File.join(wt.root, "src/new file.ts"), "export const n = 3;\n")
    patch = wt.patch
    assert_includes patch, "-export const a = 1;"
    assert_includes patch, "+export const a = 2;"
    assert_includes patch, "+export const n = 3;"
    assert_includes patch, "new file mode"
  end

  def test_remove_deletes_the_directory_but_keeps_the_branch
    wt = create
    wt.remove
    refute File.exist?(wt.root)
    assert_includes TestSupport.git!(@repo, @env, "branch", "--list", "harness/r1"), "harness/r1"
  end

  def test_git_allowlist
    allowed = [%w[status --porcelain], %w[diff HEAD], %w[add -A], ["commit", "-m", "msg"], %w[checkout -- .],
               %w[clean -fd], %w[rev-parse HEAD], %w[log --oneline], %w[worktree add -b harness/r1 /path/to/wt HEAD],
               %w[worktree remove --force /path/to/wt]]
    refused = [%w[push origin main], %w[fetch], %w[pull], %w[reset --hard], %w[checkout main], %w[clean -fdx],
               %w[config user.name x], %w[-c core.pager=x log], %w[remote add x y], %w[merge x],
               %w[worktree add /path/to/wt], %w[diff --output=/tmp/x], ["commit", "-m", "m", "--amend"],
               %w[log --exec=x], %w[status ignored-path]]
    allowed.each { |a| assert Git.allowed?(a), a.inspect }
    refused.each { |a| refute Git.allowed?(a), a.inspect }
    assert_raises(Harness::GitError) { @git.run(%w[push origin main], chdir: @repo) }
  end
end
