# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# The evidence gate (REVIEWER src/review/gate.js) and the DESIGN.md 8 rules: unseen code abstains, a needed type
# violation rejects when the typecheck passed, and the challenge abstains on unseen code.

require_relative "../test_helper"
require_relative "../support/review_fixture"

class GateTest < Minitest::Test
  RF = TestSupport::ReviewFixture
  Gate = Harness::Review::Gate
  Verify = Harness::Review::Verify
  CODE = "const { Icon, size } = ICONS[plan.icon];\nreturn <Icon size={size} />;"

  def verdict(**over)
    { "claim_type" => "repository-logic", "framework" => "none", "code_quote" => "const { Icon, size } = ICONS[plan.icon];",
      "false_statements" => [], "preconditions" => "", "trigger" => "Render the card with a plan whose icon is not a key of ICONS.",
      "refutation" => "", "refutation_quote" => "", "citations" => [], "impact" => "medium", "depends_on_unseen" => false,
      "unseen" => "", "requires_type_violation" => false, "verdict" => "accept", "reason" => "r" }.merge(over.transform_keys(&:to_s))
  end

  def decide(v, typecheck_passed: true, finding: RF.finding(file: "src/Card.tsx", problem: "An unknown icon crashes the render."))
    Gate.decide(finding: finding, verdict: v, seen: CODE, evidence: ->(_) {}, framework: "Astro", typecheck_passed: typecheck_passed)
  end

  def test_a_grounded_accept_is_accepted
    d = decide(verdict)
    assert_equal ["accept", nil], [d.outcome, d.reason]
    assert d.code_quote_valid
  end

  def test_unseen_code_abstains
    d = decide(verdict(depends_on_unseen: true, unseen: "PricingPlanType"))
    assert_equal %w[abstain verify.unseen_code], [d.outcome, d.reason]
    assert_match(/PricingPlanType/, d.reasons.first)
  end

  def test_a_needed_type_violation_is_rejected_only_when_the_typecheck_passed
    d = decide(verdict(requires_type_violation: true))
    assert_equal %w[reject verify.requires_type_violation], [d.outcome, d.reason]
    assert_equal "accept", decide(verdict(requires_type_violation: true), typecheck_passed: false).outcome
  end

  def test_quotes_must_be_verbatim_and_triggers_concrete
    assert_equal %w[abstain verify.no_evidence], decide(verdict(code_quote: "ICONS.get(plan.icon) ?? crash()")).then { |d| [d.outcome, d.reason] }
    assert_equal "abstain", decide(verdict(trigger: "sometimes")).outcome
    assert_equal "abstain", decide(verdict(false_statements: ["it is not a crash"])).outcome
  end

  def test_rejects_need_checkable_evidence
    assert_equal %w[abstain verify.no_evidence], decide(verdict(verdict: "reject")).then { |d| [d.outcome, d.reason] }
    d = decide(verdict(verdict: "reject", refutation_quote: "return <Icon size={size} />;"))
    assert_equal %w[reject verify.refuted_by_code], [d.outcome, d.reason]
  end

  def test_framework_claims_need_docs_and_other_libraries_abstain
    astro = RF.finding(file: "src/A.astro", problem: "Astro.slots.has does not exist, so the build fails.", evidence: "Astro.slots.has")
    assert Gate.framework_claim?(astro, nil, "Astro")
    d = decide(verdict, finding: astro)
    assert_equal "abstain", d.outcome
    assert_match(/framework claim without/, d.reasons.join)
    d = decide(verdict(claim_type: "framework-api", framework: "react"))
    assert_match(/no documentation source/, d.reasons.join)
  end

  def test_no_verdict_and_verifier_abstain
    assert_equal %w[abstain verify.abstained], decide(nil).then { |d| [d.outcome, d.reason] }
    assert_equal "verify.abstained", decide(verdict(verdict: "abstain")).reason
  end

  def test_quote_in_accepts_skipped_lines_in_order_only
    text = "a = fetchUser(id);\nlog(a);\nrender(a.name.toUpperCase());"
    assert Gate.quote_in?("a = fetchUser(id);\nrender(a.name.toUpperCase());", text, code: true)
    refute Gate.quote_in?("render(a.name.toUpperCase());\na = fetchUser(id);", text, code: true)
    refute Gate.quote_in?("short", text, code: true)
    assert Gate.quote_in?("    3 +a = fetchUser(id);", text, code: true), "line numbers and markers are stripped"
  end

  def test_severity_never_exceeds_the_demonstrated_impact
    assert_equal "medium", Gate.demonstrated_severity(RF.finding(severity: "high"), verdict(impact: "medium"))
    assert_equal "low", Gate.demonstrated_severity(RF.finding(severity: "high"), nil)
  end

  def test_verdicts_are_remapped_by_position_and_normalised
    v = Verify.parse_verdicts({ "verdicts" => [{ "id" => 7, "verdict" => "maybe" }, { "id" => 9, "claim_type" => "x" }] }, 2)
    assert_equal [1, 2], v.keys
    assert_equal ["abstain", "other", false], [v[1]["verdict"], v[2]["claim_type"], v[1]["depends_on_unseen"]]
    assert_raises(Harness::ParseError) { Verify.parse_verdicts({ "nope" => 1 }, 1) }
  end

  def test_the_challenge_survives_only_on_a_concrete_concession_and_abstains_on_unseen_code
    c = ->(h) { Verify.parse_challenge({ "defence" => "d", "defence_holds" => false, "concede_reason" => "", "unseen" => "" }.merge(h)) }
    assert_equal "survives", c.call("concede_reason" => "an icon outside the map throws on destructuring").result
    assert_equal "holds", c.call("concede_reason" => "short").result
    assert_equal "holds", c.call("defence_holds" => true).result
    r = c.call("concede_reason" => "the type cannot be proven because PricingPlanType is not shown", "unseen" => "PricingPlanType")
    assert_equal "abstain", r.result, "'cannot be proven because X is not shown' never survives"
    assert_equal "holds", Verify.parse_challenge("junk").result
  end
end
