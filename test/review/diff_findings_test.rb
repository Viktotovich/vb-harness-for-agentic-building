# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Ported from REVIEWER test/diff.test.js and test/findings.test.js.

require_relative "../test_helper"
require_relative "../support/review_fixture"

class DiffFindingsTest < Minitest::Test
  RF = TestSupport::ReviewFixture
  Diff = Harness::Review::Diff
  Findings = Harness::Review::Findings

  def test_prepare_skips_lockfiles_and_binaries_and_numbers_new_lines
    p = Diff.prepare(RF::SAMPLE_DIFF, max_lines: 600, max_chars: 28_000, max_chunks: 2)
    assert_equal ["app/models/user.rb"], p.chunks.first.files.map(&:path)
    assert_equal({ "package-lock.json" => "lockfile", "public/logo.png" => "binary" }, p.skipped.to_h)
    assert_includes p.chunks.first.text, "### FILE: app/models/user.rb"
    assert_includes p.chunks.first.text, %(    3 +    first_name + " " + last_name)
    assert_includes p.chunks.first.text, %(      -    "\#{first_name} \#{last_name}")
  end

  def test_large_files_are_truncated_with_a_marker
    body = (1..2000).map { |i| "+const v#{i} = #{i};" }.join("\n")
    diff = "diff --git a/src/big.js b/src/big.js\nnew file mode 100644\n--- /dev/null\n+++ b/src/big.js\n@@ -0,0 +1,2000 @@\n#{body}\n"
    p = Diff.prepare(diff, max_lines: 100, max_chars: 28_000, max_chunks: 2)
    assert_equal 1, p.chunks.size
    assert_operator p.chunks.first.lines, :<=, 100
    assert_match(/\[truncated: \d+ more diff lines/, p.chunks.first.text)
    assert p.chunks.first.files.first.added
  end

  def test_source_goes_before_config_and_docs_and_the_chunk_cap_omits
    files = { "README.md" => "+doc", "config.json" => "+{}", "src/a.ts" => "+const a = 1;" }
    diff = files.map { |p, l| "diff --git a/#{p} b/#{p}\n--- a/#{p}\n+++ b/#{p}\n@@ -1,0 +1,1 @@\n#{l}\n" }.join
    p = Diff.prepare(diff, max_lines: 4, max_chars: 28_000, max_chunks: 2)
    assert_equal [["src/a.ts"], ["config.json"]], p.chunks.map { |c| c.files.map(&:path) }
    assert_equal [["README.md", "size cap (max chunks reached)"]], p.omitted
  end

  def test_parse_handles_crlf_blank_context_and_no_newline_markers
    diff = "diff --git a/a.ts b/a.ts\r\n--- a/a.ts\r\n+++ b/a.ts\r\n@@ -1,3 +1,3 @@\r\n x\r\n\r\n-y\r\n+z\r\n\\ No newline at end of file\r\n"
    f = Diff.parse(diff).first
    assert_equal [[" ", 1, 1], [" ", 2, 2], ["-", 3, nil], ["+", nil, 3]], f.code.map { |l| [l.kind, l.old_line, l.new_line] }
  end

  def test_parse_normalises_junk_fields
    d = Findings.parse({ "summary" => 42, "findings" => [nil, "x", { "file" => "a", "line" => "12", "severity" => "HIGH" }], "suspicious" => "nope" })
    assert_equal "", d.summary
    assert_equal 1, d.findings.size
    assert_equal [12, "high", "low"], [d.findings[0].line, d.findings[0].severity, d.findings[0].confidence]
    assert_empty d.suspicious
    assert_raises(Harness::ParseError) { Findings.parse("I approve this PR!") }
  end

  def test_findings_without_a_file_or_line_are_discarded
    good = RF.finding
    raw = [good.with(file: ""), good.with(line: nil), good.with(problem: ""), good]
    kept, rejected = Findings.validate(raw, RF.files)
    assert_equal [["app/models/user.rb", 3, true]], kept.map { |k| [k.file, k.line, k.on_added_line] }
    assert_equal ["missing file", "missing or invalid line", "missing problem"], rejected.map(&:reason)
  end

  def test_mismatched_evidence_file_or_line_is_rejected_with_a_concrete_fact
    good = RF.finding
    kept, rejected = Findings.validate([
                                         good.with(evidence: "User.destroy_all"),
                                         good.with(evidence: "end"),
                                         good.with(file: "app/models/admin.rb"),
                                         good.with(file: "package-lock.json", evidence: '"x": 2'),
                                         good.with(line: 400),
                                         good.with(evidence: %(    3 +    first_name + " " + last_name), line: 4),
                                         good.with(file: "./app/models/user.rb", evidence: 'def admin? = role == "admin"', line: 6)
                                       ], RF.files)
    assert_equal ["evidence not found in diff", "evidence missing or too short", "file not in reviewed diff",
                  "file not in reviewed diff", "line does not match evidence"], rejected.map(&:reason)
    assert_includes rejected[0].fact, '"User.destroy_all" does not appear anywhere in the diff of app/models/user.rb'
    assert_includes rejected[2].fact, "not one of the files you were shown (app/models/user.rb)"
    assert_includes rejected[4].fact, "you cited line 400, but the diff of app/models/user.rb only shows lines 1-7, and your evidence is on line 3"
    assert_equal [["app/models/user.rb", 3, true], ["app/models/user.rb", 6, true]], kept.map { |k| [k.file, k.line, k.on_added_line] }
  end

  def test_duplicates_collapse_and_reconcile_keeps_provenance
    good = RF.finding
    kept, rejected = Findings.validate([good, good], RF.files)
    assert_equal [1, "duplicate"], [kept.size, rejected.first.reason]

    a = [good.with(found_by: ["discovery-1"])]
    b = [good.with(line: 4, problem: "NoMethodError raised when last_name is nil", evidence: "other", found_by: ["discovery-2"]),
         good.with(line: 6, problem: "Something else entirely about admins", evidence: "admin", found_by: ["discovery-2"])]
    merged = Findings.reconcile(a, b)
    assert_equal [%w[discovery-1 discovery-2], ["discovery-2"]], merged.map(&:found_by)
  end
end
