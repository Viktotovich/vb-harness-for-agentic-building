# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

module OneHelper
  # @return [Object] the only element, asserting there is exactly one
  def one(list)
    assert_equal 1, list.size, list.inspect
    list.first
  end
end

class RunnerTest < Minitest::Test
  include OneHelper
  G = Harness::Gates
  RUBY = RbConfig.ruby

  def setup
    @root = Dir.mktmpdir("harness-gates-")
    @runner = G::Runner.new(root: @root, env: G::Env.build(ENV), max_output: 4096)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def gate(argv, **opts)
    G::Gate.parse("check", { "argv" => argv }.merge(opts.transform_keys(&:to_s)), "gates.check")
  end

  def ruby_gate(code, **opts)
    gate([RUBY, "-e", code], **opts)
  end

  def test_exit_zero_passes
    r = @runner.run(ruby_gate("exit 0"))
    assert r.passed?
    assert_equal "passed", r.status
  end

  def test_failure_is_parsed_into_diagnostics
    out = "#{@root}/src/a.ts(3,5): error TS2322: Type 'number' is not assignable to type 'string'."
    r = @runner.run(ruby_gate("puts ARGV[0]; exit 2", parser: "tsc").then { |g| g.with(argv: g.argv + [out]) })
    assert_equal "failed", r.status
    d = r.diagnostics.first
    assert_equal ["src/a.ts", 3, 5, "TS2322"], [d.file, d.line, d.col, d.code]
  end

  def test_unparsed_output_falls_back_to_the_last_60_lines
    r = @runner.run(ruby_gate("100.times { |i| puts \"line \#{i}\" }; exit 1"))
    d = r.diagnostics.then { |list| one(list) }
    assert_equal "output", d.code
    assert_equal 60, d.message.lines.size
    assert d.message.end_with?("line 99")
  end

  def test_timeout
    r = @runner.run(ruby_gate("sleep 30", timeoutSec: 1))
    assert_equal "timeout", r.status
    refute r.passed?
  end

  def test_missing_binary_is_skipped_with_a_reason
    r = @runner.run(gate(["harness-missing-tool-#{Process.pid}", "check"]))
    assert_equal "skipped", r.status
    assert_match(/command not found/, r.reason)
    refute r.passed?
  end

  def test_a_launcher_that_cannot_find_the_tool_is_skipped
    r = @runner.run(ruby_gate("warn 'npm error could not determine executable to run'; exit 1"))
    assert_equal "skipped", r.status
    assert_match(/tool not installed/, r.reason)
  end

  # The default gates run npx --offline --no: a tool that is not installed fails at once with ENOTCACHED (no
  # download, no network), which is a missing tool, not a failure of the code.
  def test_an_offline_npx_with_a_missing_package_is_skipped
    msg = "npm error code ENOTCACHED\nnpm error request to https://registry.npmjs.org/eslint failed: cache mode is 'only-if-cached' but no cached response is available."
    r = @runner.run(ruby_gate("warn #{msg.inspect}; exit 1"))
    assert_equal "skipped", r.status
    assert_match(/tool not installed: npm error code ENOTCACHED/, r.reason)
    example = JSON.parse(File.read(File.expand_path("../../config.example.json", __dir__)))
    argvs = example.dig("stacks", "astro", "gates").values.map { |g| g["argv"] }
    assert(argvs.all? { |a| a.first(4) == ["npx", "--offline", "--no", "--"] }, "no default gate lets npx download")
  end

  def test_placeholders_expand_to_separate_arguments
    g = ruby_gate("print ARGV.join('|')", scope: "touched").then { |x| x.with(argv: x.argv + ["--", "{files}"]) }
    @runner.run(g, files: ["src/a b.ts", "-rf.ts"]).tap do |r|
      assert r.passed?
      assert_equal [RUBY, "-e", "print ARGV.join('|')", "--", "src/a b.ts", "./-rf.ts"], r.argv
    end
    assert_equal "skipped", @runner.run(g, files: []).status
    t = ruby_gate("print ARGV.size").then { |x| x.with(argv: x.argv + ["{tests}"]) }
    assert_equal [RUBY, "-e", "print ARGV.size"], @runner.run(t, tests: []).argv, "an empty {tests} runs the whole suite"
  end

  def test_placeholders_must_be_whole_arguments
    err = assert_raises(Harness::ParseError) { gate(["eslint", "--files={files}"]) }
    assert_match(/must be whole arguments/, err.message)
  end

  def test_gate_and_stack_parsing
    stack = G::Stack.parse("astro", {
                             "detect" => ["astro.config.mjs"],
                             "gates" => { "lint" => { "argv" => %w[npx eslint {files}], "scope" => "touched", "parser" => "eslint", "costRank" => 2 },
                                          "build" => { "argv" => %w[npx astro build], "when" => "integration", "costRank" => 8 } },
                             "alwaysGates" => ["lint"], "protectedPaths" => [".env*"]
                           })
    assert_equal %w[touched eslint 2 task], stack.gates["lint"].then { |g| [g.scope, g.parser, g.cost_rank.to_s, g.phase] }
    assert_equal "integration", stack.gates["build"].phase
    err = assert_raises(Harness::ParseError) { G::Stack.parse("astro", { "alwaysGates" => ["typecheck"] }) }
    assert_equal "stacks.astro.alwaysGates: no gate named \"typecheck\"", err.message
  end

  def test_result_json_round_trip
    r = @runner.run(ruby_gate("puts 'src/x.ts:1:2 - error TS1: bad'; exit 1", parser: "tsc"))
    assert_equal r, G::Result.parse(JSON.parse(JSON.generate(r.to_json_hash)))
  end
end

class ParsersTest < Minitest::Test
  include OneHelper
  P = Harness::Gates::Parsers

  def test_astro_check_and_tsc_pretty
    text = "\e[31msrc/pages/index.astro:5:7 - error ts(2322): Type 'number' is not assignable to type 'string'.\e[0m\n"
    d = P.parse("astro_check", text, root: "/path/to/repo").then { |list| one(list) }
    assert_equal ["src/pages/index.astro", 5, 7, "ts(2322)", "error"], [d.file, d.line, d.col, d.code, d.severity]
    assert_equal "Type 'number' is not assignable to type 'string'.", d.message
  end

  def test_eslint_stylish
    text = <<~OUT
      /path/to/repo/src/a.ts
        3:5   error    'x' is assigned a value but never used  no-unused-vars
        10:1  warning  Unexpected console statement            no-console

      ✖ 2 problems (1 error, 1 warning)
    OUT
    ds = P.parse("eslint", text, root: "/path/to/repo")
    assert_equal [["src/a.ts", 3, "no-unused-vars", "error"], ["src/a.ts", 10, "no-console", "warning"]],
                 ds.map { |d| [d.file, d.line, d.code, d.severity] }
    assert_equal "'x' is assigned a value but never used", ds.first.message
  end

  def test_vitest_and_playwright
    v = P.parse("vitest", " FAIL  tests/unit/price.test.ts > price > rounds up\n", root: "/r").then { |list| one(list) }
    assert_equal ["tests/unit/price.test.ts", "price > rounds up"], [v.file, v.message]
    pw = P.parse("playwright", "  1) [chromium] › tests/e2e/home.spec.ts:12:5 › home loads\n", root: "/r").then { |list| one(list) }
    assert_equal ["tests/e2e/home.spec.ts", 12, "home loads"], [pw.file, pw.line, pw.message]
  end

  def test_windows_paths_are_made_relative
    d = P.parse("tsc", "C:\\path\\to\\repo\\src\\a.ts(1,1): error TS1005: ';' expected.", root: "C:/path/to/repo").then { |list| one(list) }
    assert_equal "src/a.ts", d.file
  end
end
