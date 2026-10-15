# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# DESIGN.md 7: the bundle is filled in priority order and trimmed from the lowest priority up.

require_relative "../test_helper"
require_relative "../support/map_fixture"
require "tmpdir"

class GatherTest < Minitest::Test
  MF = TestSupport::MapFixture
  G = Harness::Task::Gather

  def setup
    @tmp = Dir.mktmpdir("harness-gather-")
    @root = MF.write(File.join(@tmp, "wt"))
    # A read file with a body much larger than its surface.
    helpers = (1..40).map { |i| "function helper#{i}(n: number): number {\n  return n + #{i};\n}\n" }.join
    File.binwrite(File.join(@root, "src/lib/format.ts"), MF::FILES["src/lib/format.ts"] + helpers)
    @map = Harness::Repo::Map.new(root: @root, cache_dir: File.join(@tmp, "cache"), protected: MF::PROTECTED)
    @task = Harness::Plan::PlanParser.parse({ "tasks" => [{
                                              "id" => "T1", "title" => "Round prices", "intent" => "Round.",
                                              "files" => { "modify" => ["src/lib/price.ts"], "read" => ["src/lib/format.ts"] },
                                              "acceptance" => [{ "kind" => "gate", "gate" => "typecheck" }]
                                            }] }).tasks.first
    @summaries = []
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def build(budget, **opts)
    summarize = lambda do |path, _content|
      @summaries << path
      "Summary of #{path}."
    end
    G.build(task: @task, root: @root, budget: budget, protected: MF::PROTECTED, task_text: "T1: Round prices",
            done: ["T0: Add tax"], map: @map, summarize: summarize, **opts)
  end

  def heads(bundle)
    bundle.sections.map { |s| s.lines.first.strip }
  end

  def test_everything_fits_in_priority_order
    b = build(100_000)
    assert_equal ["File src/lib/price.ts:", "File src/lib/format.ts:", "Signature of src/lib/tax.ts:",
                  "Signature of src/components/Price.astro:", "Summaries of related files:", "Completed tasks:"], heads(b)
    assert_empty b.omitted
    assert_equal %w[src/lib/tax.ts src/components/Price.astro], @summaries
    assert_includes b.sections[4], "src/lib/tax.ts: Summary of src/lib/tax.ts."
  end

  def test_the_lowest_priorities_are_trimmed_first
    full = build(100_000)
    # Each budget is one token short of what the previous bundle used, so the last section in drops out.
    trims = []
    b = full
    4.times do
      b = build(b.tokens - 1)
      trims << b.omitted
    end
    assert_equal [["completed tasks"],
                  ["summaries", "completed tasks"],
                  ["signature of src/components/Price.astro", "summaries", "completed tasks"],
                  ["signature of src/lib/tax.ts", "signature of src/components/Price.astro", "summaries", "completed tasks"]],
                 trims.first(4)
    trimmed = build(trims_budget_for_signature(full))
    assert_match(/\ASignature of src\/lib\/format\.ts \(the full file did not fit\):/, trimmed.sections[1],
                 "a read file that does not fit is replaced by its signature")
  end

  def test_reserved_text_counts_before_the_optional_sections
    roomy = build(100_000)
    tight = build(roomy.tokens, reserved: ["x" * 300])
    refute_empty tight.omitted
  end

  def test_a_task_whose_own_files_do_not_fit_is_too_large
    err = assert_raises(Harness::TaskTooLargeError) { build(20) }
    assert_match(/split T1: its files need ~\d+ tokens, the budget is 20/, err.message)
  end

  def test_without_a_map_read_files_are_full_or_omitted
    b = G.build(task: @task, root: @root, budget: 100_000, protected: MF::PROTECTED, task_text: "T1")
    assert_equal ["File src/lib/price.ts:", "File src/lib/format.ts:"], heads(b)
  end

  private

  # A budget with room for the modified file and the read file's signature, not its full text.
  def trims_budget_for_signature(full)
    head = Harness::Model::Tokens.estimate("T1: Round prices") + Harness::Model::Tokens.estimate(full.sections[0])
    head + Harness::Model::Tokens.estimate(full.sections[1]) - 1
  end
end
