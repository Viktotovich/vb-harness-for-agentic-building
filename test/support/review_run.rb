# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "fake_llm_server"
require_relative "run_fixture"

module TestSupport
  # A fixture repository with a type checker and a tiny test runner (Ruby scripts, so tests need no Node), for
  # review tests that confirm claims by running a test.
  module ReviewRun
    # Test files hold lines "expect_includes <path> <text>" or "expect_excludes <path> <text>".
    UNIT = <<~RUBY
      fails = ARGV.flat_map do |t|
        File.readlines(t).filter_map do |line|
          kind, path, text = line.chomp.split(" ", 3)
          next unless %w[expect_includes expect_excludes].include?(kind)

          has = File.read(path).include?(text)
          "FAIL \#{t}: \#{line.chomp}" unless kind == "expect_includes" ? has : !has
        end
      end
      puts fails
      exit(fails.empty? ? 0 : 1)
    RUBY

    FILES = RunFixture::FILES.merge(
      "tools/unit.rb" => UNIT,
      "tests/price.test.txt" => "expect_includes src/lib/price.ts export function price\n",
      "src/types.ts" => "export type PlanIcon = \"star\" | \"bolt\";\nexport type Billing = \"monthly\" | \"yearly\";\n" \
                        "export interface Plan { icon: PlanIcon; prices: Record<Billing, number> }\n",
      "src/components/icons.ts" => "export const ICONS = { star: { Icon: Star, size: 16 }, bolt: { Icon: Bolt, size: 20 } };\n"
    ).freeze

    # @return [Harness::Config] the run fixture's stack plus a unit gate
    def self.config(base_url)
      Harness::Config.parse(raw_config(base_url))
    end

    # @return [Hash] the same config as JSON
    def self.raw_config(base_url)
      ruby = RbConfig.ruby
      {
        "profiles" => { "default" => { "baseUrl" => base_url, "maxOutputTokens" => 1000, "timeoutSec" => 30 } },
        "gateEnvAllow" => %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM],
        "stacks" => { "astro" => {
          "detect" => ["astro.config.mjs"],
          "gates" => {
            "typecheck" => { "argv" => [ruby, "tools/typecheck.rb"], "parser" => "astro_check", "costRank" => 3 },
            "unit" => { "argv" => [ruby, "tools/unit.rb", "{tests}"], "scope" => "tests", "costRank" => 4 }
          },
          "alwaysGates" => ["typecheck"],
          "protectedPaths" => [".env*", "tools/**"]
        } }
      }
    end

    # @param system [String] a request's system prompt
    # @return [String, nil] the review stage it belongs to
    def self.stage(system)
      RunFixture::REVIEW_ROLES.find { |opening, _| system.start_with?(opening) }&.last
    end

    # @return [Array(Integer, Hash)] a discovery reply
    def self.discovery(findings)
      FakeLlmServer.ok(JSON.generate({ "summary" => "A change.", "findings" => findings, "suspicious" => [] }))
    end

    # @return [Hash] one discovery finding
    def self.claim(file, line, problem, evidence)
      { "file" => file, "line" => line, "severity" => "high", "confidence" => "high", "problem" => problem,
        "evidence" => evidence, "mechanism" => "", "preconditions" => "", "expected_actual" => "", "unverified" => "" }
    end

    # @return [Hash] one verifier verdict
    def self.verdict(id, quote, **over)
      { "id" => id, "claim_type" => "repository-logic", "framework" => "none", "code_does" => "d", "code_quote" => quote,
        "false_statements" => [], "preconditions" => "", "trigger" => "Render it with the input the claim describes.",
        "refutation" => "", "refutation_quote" => "", "citations" => [], "impact" => "high", "depends_on_unseen" => false,
        "unseen" => "", "requires_type_violation" => false, "verdict" => "accept", "reason" => "r" }.merge(over.transform_keys(&:to_s))
    end

    # @return [Array(Integer, Hash)] a native tool call
    def self.tool_call(name, args)
      FakeLlmServer.ok("", tool_calls: [{ "id" => "c1", "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }])
    end

    # @return [Array(Integer, Hash)] a confirming test at the path the prompt names
    def self.confirm_test(system, content)
      path = system[/"path": "([^"]+)"/, 1]
      FakeLlmServer.ok(JSON.generate({ "edits" => [], "tests" => [{ "op" => "create", "path" => path, "content" => content }], "notes" => "t" }))
    end

    # @return [String] every message of a request, joined
    def self.text(body)
      body["messages"].map { |m| m["content"].to_s }.join("\n")
    end
  end
end
