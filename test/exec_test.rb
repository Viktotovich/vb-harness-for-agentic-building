# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "test_helper"

# Basic Exec behaviour used by bin/check. Timeouts, output caps and Windows resolution are
# covered in M1.
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
end
