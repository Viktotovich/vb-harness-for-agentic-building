# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

class PathsTest < Minitest::Test
  P = Harness::Repo::Paths
  PROTECTED = [".git/**", ".env*", "**/*.lock", "package-lock.json", "pnpm-lock.yaml", ".github/**"].freeze

  def setup
    @tmp = Dir.mktmpdir("harness-paths-")
    @root = File.join(@tmp, "wt")
    FileUtils.mkdir_p(File.join(@root, "src"))
    @outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p(@outside)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def resolve(path)
    P.resolve_in_worktree(@root, path, protected: PROTECTED)
  end

  def reason(path)
    assert_raises(Harness::PathError, path.inspect) { resolve(path) }.reason
  end

  def test_relative_paths_resolve_inside_the_root
    real = File.realpath(@root)
    assert_equal File.join(real, "src/a.ts"), resolve("src/a.ts")
    assert_equal File.join(real, "a.ts"), resolve("src/../a.ts")
    assert_equal File.join(real, "src/new/deep.ts"), resolve("./src\\new/deep.ts")
  end

  def test_escapes_and_absolute_paths_are_refused
    ["../x", "src/../../x", "/etc/passwd", "C:\\Windows\\x", "c:x", "\\\\server\\share\\x", "~/x", "", "  ",
     "a\0b", "file.txt:stream", ".", "src/.."].each do |path|
      assert_equal P::OUTSIDE, reason(path)
    end
    assert_equal P::OUTSIDE, assert_raises(Harness::PathError) { resolve(nil) }.reason
  end

  def test_protected_paths_are_refused
    [".git/config", ".GIT/hooks/pre-commit", ".env", ".env.local", "yarn.lock", "packages/a/yarn.lock",
     ".github/workflows/ci.yml", "package-lock.json"].each do |path|
      assert_equal P::PROTECTED, reason(path), path
    end
    assert resolve("src/environment.ts")
    assert resolve("docs/locking.md")
  end

  def test_git_is_protected_even_without_patterns
    assert_raises(Harness::PathError) { P.resolve_in_worktree(@root, ".git/HEAD") }
    assert_raises(Harness::PathError) { P.resolve_in_worktree(@root, ".husky/pre-commit") }
  end

  # Windows resolves ".git." and ".git " to .git, and a short name such as GIT~1 to a long one.
  def test_windows_path_aliases_are_refused
    { ".git./config" => "dot or a space", ".git /config" => "dot or a space", "src/a.ts." => "dot or a space",
      "GIT~1/config" => "short name", "src/PROGRA~1/x.ts" => "short name", ".husky /pre-commit" => "dot or a space" }.each do |path, why|
      err = assert_raises(Harness::PathError, path.inspect) { P.resolve_in_worktree(@root, path) }
      assert_match(/#{why}/, err.message, path)
    end
    assert resolve("src/../src/a.ts"), ".. segments are still resolved"
    assert resolve("src/v1.2/a.ts")
  end

  def symlink_or_skip(target, link)
    File.symlink(target, link)
  rescue NotImplementedError, SystemCallError => e
    skip "symlinks unavailable here (#{e.class})"
  end

  def test_a_symlinked_directory_pointing_outside_is_refused
    symlink_or_skip(@outside, File.join(@root, "escape"))
    assert_equal P::OUTSIDE, reason("escape/new.ts")
  end

  def test_a_symlinked_file_pointing_outside_is_refused
    File.write(File.join(@outside, "secret.txt"), "x")
    symlink_or_skip(File.join(@outside, "secret.txt"), File.join(@root, "src", "link.txt"))
    assert_equal P::OUTSIDE, reason("src/link.txt")
  end

  def test_a_symlink_inside_the_root_is_fine
    symlink_or_skip(File.join(@root, "src"), File.join(@root, "alias"))
    assert resolve("alias/a.ts")
  end
end
