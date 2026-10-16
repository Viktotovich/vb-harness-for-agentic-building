# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "test_helper"

class CliTest < Minitest::Test
  def run_cli(*argv)
    out = TestSupport::Sink.new
    err = TestSupport::Sink.new
    code = Harness::CLI.run(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  def test_version_prints_semver_and_exits_zero
    code, out, = run_cli("--version")
    assert_equal 0, code
    assert_equal Harness::VERSION, out.strip
    assert_match(/\A\d+\.\d+\.\d+\z/, Harness::VERSION)
  end

  def test_help_lists_commands
    code, out, = run_cli("--help")
    assert_equal 0, code
    assert_includes out, "Usage: harness"
    assert_includes out, "push"
    assert_includes out, "Documentation: https://vb-harness.vandbruno.net"
  end

  def test_unknown_command_is_a_config_error
    code, _out, err = run_cli("frobnicate")
    assert_equal 2, code
    assert_includes err, "unknown command"
  end

  def test_unimplemented_command_says_so
    code, _out, err = run_cli("cleanup")
    assert_equal 2, code
    assert_includes err, "not implemented yet"
  end

  def test_unknown_flag_is_a_config_error
    code, _out, err = run_cli("--nope")
    assert_equal 2, code
    assert_includes err, "invalid option"
  end
end
