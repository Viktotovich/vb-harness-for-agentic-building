# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "test_helper"

require "fileutils"
require "tmpdir"

# Harness::Exec: argv only, scrubbed env, timeout, output cap, Windows PATHEXT and batch-file safety.
class ExecTest < Minitest::Test
  RUBY = RbConfig.ruby

  def run_cmd(argv, **opts)
    Harness::Exec.run(argv, chdir: TestSupport::ROOT, env: TestSupport.child_env, **opts)
  end

  def test_captures_stdout_stderr_and_exit_code
    r = run_cmd([RUBY, "-e", "puts 1; warn 2; exit 3"])
    assert_equal "1\n", r.stdout.delete("\r")
    assert_equal "2\n", r.stderr.delete("\r")
    assert_equal 3, r.exit_code
    refute r.success?
  end

  def test_arguments_are_not_interpreted_by_a_shell
    r = run_cmd([RUBY, "-e", "print ARGV.join('|')", "a b", "$HOME", "x;y", "&"])
    assert_equal "a b|$HOME|x;y|&", r.stdout
  end

  def test_child_sees_only_the_given_environment
    ENV["HARNESS_TEST_SECRET"] = "parent-only"
    r = Harness::Exec.run([RUBY, "-e", "print ENV.key?('HARNESS_TEST_SECRET'), ENV['A']"],
                          chdir: TestSupport::ROOT, env: TestSupport.child_env.merge("A" => "1"))
    assert_equal "false1", r.stdout
  ensure
    ENV.delete("HARNESS_TEST_SECRET")
  end

  def test_rejects_malformed_argv
    assert_raises(ArgumentError) { run_cmd("ls -la") }
    assert_raises(ArgumentError) { run_cmd([]) }
    assert_raises(ArgumentError) { run_cmd(["ls", :x]) }
  end

  def test_missing_executable_raises_command_not_found
    assert_raises(Harness::CommandNotFoundError) { run_cmd(["harness-no-such-binary-#{Process.pid}"]) }
  end

  # --- timeout and output cap ---

  def test_timeout_kills_the_process_tree
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = run_cmd([RUBY, "-e", "$stdout.sync = true; puts :started; sleep 30"], timeout: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert r.timed_out
    assert_nil r.exit_code
    refute r.success?
    assert_includes r.stdout, "started"
    assert_operator elapsed, :<, 15, "the child was killed, not waited for"
  end

  def test_output_is_capped_per_stream
    r = run_cmd([RUBY, "-e", "$stdout.write('a' * 100_000); $stderr.write('b' * 10)"], max_output: 1000)
    assert_equal 1000, r.stdout.bytesize
    assert_equal "b" * 10, r.stderr
    assert r.truncated
    assert r.success?, "a capped stream still lets the process finish"
  end

  def test_small_output_is_not_truncated
    refute run_cmd([RUBY, "-e", "print 1"]).truncated
  end

  # --- Windows resolution, testable on any OS with windows: true ---

  def with_bin_dir
    Dir.mktmpdir("harness exec ") do |dir|
      bin = File.join(dir, "node bin")
      FileUtils.mkdir_p(bin)
      yield dir, bin
    end
  end

  def test_resolve_follows_pathext_and_skips_extensionless_scripts
    with_bin_dir do |dir, bin|
      File.write(File.join(bin, "npx"), "#!/bin/sh
")   # the POSIX shim Windows cannot run
      File.write(File.join(bin, "npx.cmd"), "@echo off
")
      path = [File.join(dir, "empty"), bin].join(";")
      assert_equal File.join(bin, "npx.cmd"), Harness::Exec.resolve("npx", path: path, pathext: ".COM;.EXE;.CMD", windows: true)
      assert_equal File.join(bin, "npx.cmd"), Harness::Exec.resolve("npx.cmd", path: path, pathext: nil, windows: true)
      assert_nil Harness::Exec.resolve("npx", path: path, pathext: ".EXE", windows: true)
      assert_equal "C:/tools/x.exe", Harness::Exec.resolve("C:/tools/x.exe", path: path, pathext: nil, windows: true)
    end
  end

  def test_batch_files_refuse_cmd_metacharacters
    with_bin_dir do |_dir, bin|
      File.write(File.join(bin, "npx.cmd"), "@echo off
")
      env = { "PATH" => bin, "PATHEXT" => ".CMD" }
      ["a&b", "a|b", "a<b", "a>b", "a^b", "%PATH%", "say \"hi\"", "two
lines", "crx"].each do |arg|
        err = assert_raises(Harness::UnsafeArgumentError, arg.inspect) { Harness::Exec.prepare(["npx", "eslint", arg], env) }
        assert_includes err.message, "npx.cmd"
      end
      assert_equal [File.join(bin, "npx.cmd"), "eslint", "src/a b.ts"], Harness::Exec.prepare(["npx", "eslint", "src/a b.ts"], env)
    end
  end

  def test_metacharacters_are_fine_for_real_executables
    with_bin_dir do |_dir, bin|
      File.write(File.join(bin, "tool.exe"), "")
      env = { "PATH" => bin, "PATHEXT" => ".EXE;.CMD" }
      assert_equal [File.join(bin, "tool.exe"), "a&b"], Harness::Exec.prepare(["tool", "a&b"], env)
    end
  end

  def test_prepare_reports_a_missing_command
    assert_raises(Harness::CommandNotFoundError) { Harness::Exec.prepare(["nope"], { "PATH" => "", "PATHEXT" => ".EXE" }) }
  end

  def test_windows_runs_a_cmd_file_from_a_path_with_spaces
    skip "Windows only" unless Harness::Exec.windows?

    with_bin_dir do |_dir, bin|
      File.write(File.join(bin, "hello.cmd"), "@echo off
echo ONE=[%~1] TWO=[%~2]
")
      env = TestSupport.child_env.merge("PATH" => "#{bin};#{ENV.fetch('PATH')}")
      r = Harness::Exec.run(["hello", "a b", "c"], chdir: TestSupport::ROOT, env: env)
      assert r.success?, r.stderr
      assert_equal "ONE=[a b] TWO=[c]", r.stdout.strip
      assert_equal ["hello", "a b", "c"], r.argv, "the result shows the argv as given"
    end
  end
end
