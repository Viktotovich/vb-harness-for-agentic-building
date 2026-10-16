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
    FileUtils.mkdir_p(File.join(from, ".vite", "deps"))
    File.write(File.join(from, ".vite", "deps", "chunk.js"), "cache")
    result = Harness::Repo::Mirror.link(from, to)
    assert_equal [2, []], [result.files, result.skipped]
    refute File.exist?(File.join(to, ".vite")), "tool caches are not mirrored: tools rebuild them and change them while running"
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

  # I11: a mirrored file is a hard link into the user's checkout. Writing it in the worktree must never change the
  # original, and edits from a model may not target it at all.
  def test_writing_a_mirrored_file_leaves_the_users_original_unchanged
    files = F::FILES.merge(".gitignore" => "node_modules/\nvendor-deps/\n")
    repo, env = TestSupport.repo(@tmp, files)
    { "node_modules/tool/index.js" => "original();\n", "vendor-deps/lib.js" => "original lib\n" }.each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(repo, rel)))
      File.write(File.join(repo, rel), text)
    end
    raw = { "profiles" => { "default" => { "baseUrl" => "http://127.0.0.1:9/v1" } },
            "gateEnvAllow" => %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM],
            "stacks" => { "astro" => { "detect" => ["astro.config.mjs"], "dependencyDirs" => %w[node_modules vendor-deps] } } }
    config = Harness::Config.parse(raw)
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "m2")
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    mirrored = File.join(setup.worktree.root, "node_modules/tool/index.js")
    original = File.join(repo, "node_modules/tool/index.js")
    linked = File.identical?(mirrored, original)

    Harness::Repo::AtomicFile.write(mirrored, "changed in the worktree();\n")
    assert_equal "original();\n", File.read(original), "the user's file is untouched#{linked ? ' (it was a hard link)' : ''}"
    assert_equal "changed in the worktree();\n", File.read(mirrored)
    refute File.identical?(mirrored, original), "the write broke the link"

    %w[node_modules/tool/index.js vendor-deps/lib.js node_modules].each do |rel|
      assert Harness::Repo::Paths.protected?(rel, setup.stack.protected_paths), rel
    end
    set = Harness::Task::EditSet.parse({ "edits" => [{ "op" => "replace", "path" => "vendor-deps/lib.js", "search" => "original lib",
                                                       "replace" => "pwned" }] })
    result = Harness::Task::Edits.apply(root: setup.worktree.root, edit_set: set, modify: ["vendor-deps/lib.js"], create: [],
                                        protected: setup.stack.protected_paths)
    refute result.ok?
    assert_equal "edit.protected_path", result.rejections.first.reason
    assert_equal "original lib\n", File.read(File.join(repo, "vendor-deps/lib.js"))
    assert_equal "original lib\n", File.read(File.join(setup.worktree.root, "vendor-deps/lib.js"))
  end

  def test_edits_replace_files_instead_of_writing_through_links
    root = File.join(@tmp, "wt")
    FileUtils.mkdir_p(File.join(root, "src"))
    outside = File.join(@tmp, "outside.ts")
    File.write(outside, "export const a = 1;\n")
    begin
      File.link(outside, File.join(root, "src", "a.ts"))
    rescue SystemCallError, NotImplementedError => e
      skip "hard links unavailable here (#{e.class})"
    end
    set = Harness::Task::EditSet.parse({ "edits" => [{ "op" => "replace", "path" => "src/a.ts", "search" => "1;", "replace" => "2;" }] })
    assert Harness::Task::Edits.apply(root: root, edit_set: set, modify: ["src/a.ts"], create: []).ok?
    assert_equal "export const a = 2;\n", File.read(File.join(root, "src", "a.ts"))
    assert_equal "export const a = 1;\n", File.read(outside), "an edit never writes through a hard link"
  end

  def test_dependency_dirs_are_plain_folder_names
    ["../outside", "a/b", ".git", ""].each do |bad|
      raw = { "detect" => ["x"], "dependencyDirs" => [bad] }
      assert_raises(Harness::ParseError, bad.inspect) { Harness::Gates::Stack.parse("s", raw) }
    end
    assert_equal ["node_modules"], Harness::Gates::Stack.parse("s", { "dependencyDirs" => ["node_modules"] }).dependency_dirs
  end
end
