# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# dependencyDirs: git-ignored folders (node_modules) are mirrored into each worktree so gates can run there.

require_relative "../test_helper"
require_relative "../support/run_fixture"
require "tmpdir"

class MirrorTest < Minitest::Test
  F = TestSupport::RunFixture

  def setup
    @tmp = Dir.mktmpdir("harness-mirror-")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_files_are_mirrored_and_an_existing_target_is_left_alone
    from = File.join(@tmp, "repo", "node_modules")
    FileUtils.mkdir_p(File.join(from, "astro", "bin"))
    File.write(File.join(from, "astro", "bin", "astro.mjs"), "run()")
    File.write(File.join(from, ".package-lock.json"), "{}")
    to = File.join(@tmp, "wt", "node_modules")
    assert_equal 2, Harness::Repo::Mirror.link(from, to)
    assert_equal "run()", File.read(File.join(to, "astro", "bin", "astro.mjs"))
    assert_nil Harness::Repo::Mirror.link(from, to), "an existing folder is never overwritten"
    assert_nil Harness::Repo::Mirror.link(File.join(@tmp, "missing"), File.join(@tmp, "x"))
  end

  def test_intake_mirrors_the_stacks_dependency_dirs
    files = F::FILES.merge(".gitignore" => "node_modules/\n")
    repo, env = TestSupport.repo(@tmp, files)
    FileUtils.mkdir_p(File.join(repo, "node_modules", "tool"))
    File.write(File.join(repo, "node_modules", "tool", "index.js"), "module.exports = 1;\n")
    raw = { "profiles" => { "default" => { "baseUrl" => "http://127.0.0.1:9/v1" } },
            "gateEnvAllow" => %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM],
            "stacks" => { "astro" => { "detect" => ["astro.config.mjs"], "dependencyDirs" => ["node_modules"],
                                       "gates" => { "typecheck" => { "argv" => [RbConfig.ruby, "-e", "exit File.file?('node_modules/tool/index.js') ? 0 : 1"] } } } } }
    config = Harness::Config.parse(raw)
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "m1")
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    assert File.file?(File.join(setup.worktree.root, "node_modules", "tool", "index.js"))
    assert_equal "passed", setup.baseline["typecheck"].status, "the gate sees the dependencies"
    refute setup.worktree.dirty?, "ignored folders do not show as changes"
    assert(Harness::State::Events.read(store.events_path).any? { |e| e["subject"] == "node_modules" && e["detail"] == "1 files linked into the worktree" })
  end

  def test_dependency_dirs_are_plain_folder_names
    ["../outside", "a/b", ".git", ""].each do |bad|
      raw = { "detect" => ["x"], "dependencyDirs" => [bad] }
      assert_raises(Harness::ParseError, bad.inspect) { Harness::Gates::Stack.parse("s", raw) }
    end
    assert_equal ["node_modules"], Harness::Gates::Stack.parse("s", { "dependencyDirs" => ["node_modules"] }).dependency_dirs
  end
end
