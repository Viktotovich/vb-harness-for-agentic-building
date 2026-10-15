# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# M6 acceptance (DESIGN.md 13): replays of the false-positive patterns REVIEWER published, on synthetic code.
# - #56: a claim needing a value outside its declared type (an icon key the union does not allow) and a claim
#   resting on code nobody fetched;
# - #57: a claim the verifier and the challenge both accepted, which a test does not confirm;
# - #60: a claim the challenge defends once it fetches the line that refutes it.
# None of them may become a Finding.

require_relative "../test_helper"
require_relative "../support/review_run"
require "tmpdir"

class ReplayTest < Minitest::Test
  RR = TestSupport::ReviewRun
  Fake = TestSupport::FakeLlmServer

  CARD = <<~TSX
    import type { Plan, Billing } from "../types";
    import { ICONS } from "./icons";

    export function PricingCard({ plan, billing }: { plan: Plan; billing: Billing }) {
      const { Icon, size } = ICONS[plan.icon];
      return <p><Icon size={size} />{price.format(plan.prices[billing])}</p>;
    }
  TSX
  STEPS = <<~TS
    export function watch(steps: Element[], show: (i: number) => void) {
      const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) if (entry.isIntersecting) show(steps.indexOf(entry.target));
      });
      steps.forEach((s) => observer.observe(s));
    }
  TS
  CACHE = <<~TS
    export async function page(db: Db, cache: Cache, slug: string) {
      const version = await db.contentVersion(slug);
      const key = `${slug}:${version}`;
      return (await cache.get(key)) ?? render(slug);
    }
  TS
  ICON_LINE = "const { Icon, size } = ICONS[plan.icon];"
  PRICE_LINE = "return <p><Icon size={size} />{price.format(plan.prices[billing])}</p>;"
  STEP_LINE = "for (const entry of entries) if (entry.isIntersecting) show(steps.indexOf(entry.target));"
  CACHE_LINE = "return (await cache.get(key)) ?? render(slug);"

  CLAIMS = [
    RR.claim("src/components/PricingCard.tsx", 5, "ICONS[plan.icon] is read without a check, so an unknown icon crashes the render.", ICON_LINE),
    RR.claim("src/components/PricingCard.tsx", 6, "plan.prices[billing] has no null check, so a missing price renders NaN.", PRICE_LINE),
    RR.claim("src/lib/steps.ts", 3, "show() runs only when a step enters, so the sequence never moves backward.", STEP_LINE),
    RR.claim("src/lib/cache.ts", 4, "A publish can be served stale from the cache after the content changes.", CACHE_LINE)
  ].freeze

  def setup
    @tmp = Dir.mktmpdir("harness-replay-")
    @server = Fake.new { |body, _n| reply(body) }
    repo, @env = TestSupport.repo(@tmp, RR::FILES)
    @config = RR.config(@server.base_url)
    @store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "replay")
    @setup = Harness::Run.intake(config: @config, repo: repo, store: @store, parent_env: ENV.to_h.merge(@env))
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@tmp)
  end

  # The scripted model: discovery proposes the four claims, the verifier fetches the PricingCard's type and then
  # judges, the challenge fetches cache.ts before defending it, and the fixer writes a test for the steps claim.
  def reply(body)
    system = body["messages"].first["content"]
    all = RR.text(body)
    fetched = body["messages"].any? { |m| m["role"] == "tool" }
    case RR.stage(system)
    when nil then raise "unexpected request: #{system[0, 60]}"
    when "review"
      RR.discovery(system.start_with?("You are a careful") ? CLAIMS : [])
    when "verify"
      return RR.tool_call("find_symbol", { "name" => "Plan" }) if body["tools"] && all.include?("PricingCard") && !fetched
      return Fake.ok("DONE") if body["tools"] || !all.include?("Now give your verdicts")

      verdicts = if all.include?("PricingCard.tsx")
                   [RR.verdict(1, ICON_LINE, requires_type_violation: true, reason: "PlanIcon is a union of the ICONS keys"),
                    RR.verdict(2, PRICE_LINE, depends_on_unseen: true, unseen: "price.format"),
                    RR.verdict(3, STEP_LINE)]
                 else
                   [RR.verdict(1, CACHE_LINE)]
                 end
      Fake.ok(JSON.generate({ "verdicts" => verdicts }))
    when "challenge"
      if all.include?("src/lib/cache.ts")
        return RR.tool_call("read_file", { "path" => "src/lib/cache.ts", "start_line" => 1, "end_line" => 5 }) if body["tools"] && !fetched
        return Fake.ok("DONE") if body["tools"]

        Fake.ok(JSON.generate({ "defence" => "The key includes the content version read on every request (line 3), so a stale copy cannot match.",
                                "defence_holds" => true, "concede_reason" => "", "unseen" => "" }))
      else
        return Fake.ok("DONE") if body["tools"]

        Fake.ok(JSON.generate({ "defence" => "none", "defence_holds" => false, "unseen" => "",
                                "concede_reason" => "Scrolling back up never calls show with an earlier index." }))
      end
    when "confirm" then RR.confirm_test(system, "expect_includes src/lib/steps.ts entry.isIntersecting\n")
    else raise "no reply for #{RR.stage(system)}"
    end
  end

  def write(rel, text)
    full = File.join(@setup.worktree.root, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def test_the_replayed_claims_never_become_findings
    write("src/components/PricingCard.tsx", CARD)
    write("src/lib/steps.ts", STEPS)
    write("src/lib/cache.ts", CACHE)
    typecheck = Harness::Gates::Baseline.compare(@setup.runner.run(@setup.stack.gates["typecheck"]), @setup.baseline["typecheck"])
    assert typecheck.ok?
    map = Harness::Repo::Map.new(root: @setup.worktree.root, protected: @setup.stack.protected_paths)
    reviewer = Harness::Review::Reviewer.new(client: TestSupport::RunFixture.client(@config, @store), config: @config,
                                             worktree: @setup.worktree, stack: @setup.stack, runner: @setup.runner,
                                             baseline: @setup.baseline, events: @setup.events, store: @store, map: map)
    task = Harness::Plan::PlanParser.parse({ "tasks" => [TestSupport::RunFixture.task("T1", "Pricing", modify: ["src/types.ts"])] }).tasks.first
    record = reviewer.call(task: task, diff: @setup.worktree.patch(context: 10), gates: [typecheck])

    assert_empty @server.errors
    assert_empty record["findings"], "I8: nothing unconfirmed is a finding"
    assert_empty reviewer.follow_ups("T1")
    by_id = (record["rejected"] + record["abstained"] + record["questions"]).to_h { |c| [c["id"], c["reason"]] }
    assert_equal({ "C1" => "verify.requires_type_violation", "C2" => "verify.unseen_code", "C3" => "confirm.test_passes",
                   "C4" => "challenge.defence_holds" }, by_id)
    assert_equal ["C3"], record["questions"].map { |q| q["id"] }, "the claim that survived the challenge goes to Questions"
    refute(Dir.glob(File.join(@setup.worktree.root, "tests", "harness-confirm-*")).any?, "the confirming test is removed")

    verify = @server.chat_bodies.select { |b| RR.stage(b["messages"].first["content"]) == "verify" }
    assert(verify.any? { |b| RR.text(b).include?("export type PlanIcon") || RR.text(b).include?("export interface Plan") },
           "the verifier saw the declared type through find_symbol")
    refute(verify.any? { |b| b["messages"].last["content"].match?(/severity|confidence/i) }, "verification never sees severity")
    reasons = Harness::State::Events.read(@store.events_path).map { |e| e["reason"] }.compact
    assert_includes reasons, "verify.requires_type_violation"
    assert_includes reasons, "confirm.test_passes"
    assert File.file?(File.join(@store.task_dir("T1"), "review.json"))
  end
end
