# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

class BaselineTest < Minitest::Test
  G = Harness::Gates
  B = G::Baseline

  def diag(file, code, message, line: 1)
    G::Diagnostic.new(file: file, line: line, col: 1, code: code, message: message, severity: "error")
  end

  def result(status, diags = [])
    G::Result.new(gate: "typecheck", status: status, exit_code: status == "passed" ? 0 : 1, diagnostics: diags,
                  reason: status == "skipped" ? "command not found" : nil, ms: 5, argv: %w[npx astro check])
  end

  A = ["src/a.ts", "TS2322", "Type mismatch"].freeze
  C = ["src/c.ts", "TS2304", "Cannot find name 'x'"].freeze

  def test_a_failure_already_present_at_baseline_does_not_block
    cmp = B.compare(result("failed", [diag(*A, line: 9)]), result("failed", [diag(*A, line: 3)]))
    assert_equal "baseline_same", cmp.verdict
    assert cmp.ok?, "line numbers move; the same file, code and message is the same problem"
  end

  def test_only_new_diagnostics_block
    cmp = B.compare(result("failed", [diag(*A), diag(*C)]), result("failed", [diag(*A)]))
    assert_equal "regressed", cmp.verdict
    assert_equal [C], cmp.new_diagnostics.map { |d| [d.file, d.code, d.message] }
    refute cmp.ok?
  end

  def test_diagnostics_are_counted_as_a_multiset
    cmp = B.compare(result("failed", [diag(*A), diag(*A, line: 2)]), result("failed", [diag(*A)]))
    assert_equal 1, cmp.new_diagnostics.size
  end

  def test_pass_regress_and_skip
    assert_equal "pass", B.compare(result("passed"), result("failed", [diag(*A)])).verdict
    assert_equal "regressed", B.compare(result("failed", [diag(*A)]), result("passed")).verdict
    assert_equal "regressed", B.compare(result("failed", [diag(*A)]), nil).verdict
    skipped = B.compare(result("skipped"), result("passed"))
    assert_equal "skipped", skipped.verdict
    refute skipped.ok?, "I6: a skipped gate never counts as passed"
  end

  def test_timeouts_compare_by_status
    assert_equal "baseline_same", B.compare(result("timeout"), result("timeout")).verdict
    assert_equal "regressed", B.compare(result("timeout"), result("failed", [diag(*A)])).verdict
  end

  def test_unparsed_output_compares_by_text
    tail = ["", "output", "3 tests failed"]
    assert_equal "baseline_same", B.compare(result("failed", [diag(nil, "output", tail[2])]),
                                            result("failed", [diag(nil, "output", tail[2])])).verdict
    assert_equal "regressed", B.compare(result("failed", [diag(nil, "output", "4 tests failed")]),
                                        result("failed", [diag(nil, "output", tail[2])])).verdict
  end

  def test_save_and_load_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "runs", "r1", "baseline.json")
      results = { "typecheck" => result("failed", [diag(*A)]), "unit" => result("skipped") }
      B.save(path, results)
      assert_equal results, B.load(path)
    end
  end

  # End to end with real subprocesses: a project gate that already fails at baseline, and still fails the
  # same way after the task, does not block; a new failure does.
  def test_baseline_run_and_compare_with_real_gates
    Dir.mktmpdir do |root|
      runner = G::Runner.new(root: root, env: G::Env.build(ENV))
      script = ->(lines) { [RbConfig.ruby, "-e", "puts #{lines.inspect}; exit 1"] }
      gates = {
        "typecheck" => G::Gate.parse("typecheck", { "argv" => script.call(["src/a.ts:1:1 - error TS1: old"]), "parser" => "tsc", "costRank" => 3 }, "g"),
        "lint" => G::Gate.parse("lint", { "argv" => %w[x {files}], "scope" => "touched" }, "g")
      }
      base = B.run(runner, gates)
      assert_equal ["typecheck"], base.keys, "touched-scope gates need files and are not part of the baseline"
      same = runner.run(gates["typecheck"])
      assert B.compare(same, base["typecheck"]).ok?
      worse = runner.run(gates["typecheck"].with(argv: script.call(["src/a.ts:1:1 - error TS1: old", "src/b.ts:2:2 - error TS2: new"])))
      cmp = B.compare(worse, base["typecheck"])
      refute cmp.ok?
      assert_equal ["src/b.ts"], cmp.new_diagnostics.map(&:file)
    end
  end
end
