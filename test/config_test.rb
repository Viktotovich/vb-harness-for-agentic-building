# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "test_helper"
require "fileutils"
require "json"
require "tmpdir"

class ConfigTest < Minitest::Test
  BASE = { "baseUrl" => "http://127.0.0.1:8080/v1" }.freeze

  def parse(raw, env: {})
    Harness::Config.parse(raw, env: env)
  end

  def error(raw)
    assert_raises(Harness::ParseError) { parse(raw) }.message
  end

  def test_defaults_from_the_spec
    c = parse({ "profiles" => { "default" => BASE } })
    p = c.profiles["default"]
    assert_equal ["auto", "probe", 4000, 900, nil], [p.model, p.context_tokens, p.max_output_tokens, p.timeout_sec, p.api_key_env]
    assert_equal %w[probe low], [p.thinking.control, p.thinking.effort]
    assert_equal [3, 3, 2, 20, 6, 2, 4096, 204_800], c.limits.to_h.values
    assert_equal false, c.dry_run
    assert(Harness::Model::ROLES.all? { |r| c.roles[r] == "default" })
  end

  def test_config_example_parses_and_uses_only_placeholders
    raw = JSON.parse(File.read(File.join(TestSupport::ROOT, "config.example.json")))
    c = parse(raw)
    assert_equal "http://127.0.0.1:8080/v1", c.profiles["default"].base_url
    assert_nil c.profiles["default"].api_key_env
  end

  def test_role_defaults_follow_the_named_roles
    c = parse({ "profiles" => { "small" => BASE, "big" => BASE },
                "roles" => { "planner" => "big", "implementer" => "small", "reviewer" => "big" } })
    assert_equal %w[small big small], %i[fixer verifier summarizer].map { |r| c.roles[r] }
    assert_equal "small", c.profile_for(:fixer).name
  end

  def test_precise_errors
    assert_equal "profiles.default.baseUrl: expected http(s) URL, got nil", error({ "profiles" => { "default" => {} } })
    assert_equal "profiles.default.thinking.control: expected one of probe, chat_template_kwargs, reasoning_effort, " \
                 "budget, none, got \"on\"",
                 error({ "profiles" => { "default" => BASE.merge("thinking" => { "control" => "on" }) } })
    assert_match(/\Aroles.planner: no profile named "big"/, error({ "profiles" => { "default" => BASE }, "roles" => { "planner" => "big" } }))
    assert_match(/\AmaxFixRounds: expected integer >= 1/, error({ "profiles" => { "default" => BASE }, "maxFixRounds" => 0 }))
    assert_match(/\Amaxfixrounds: unknown key/, error({ "profiles" => { "default" => BASE }, "maxfixrounds" => 2 }))
    assert_equal "profiles: at least one profile is required", error({ "profiles" => {} })
  end

  def test_api_key_env_must_be_a_variable_name_not_a_key
    msg = error({ "profiles" => { "default" => BASE.merge("apiKeyEnv" => "abc-123 secret") } })
    assert_includes msg, "not the key itself"
    refute_includes msg, "abc-123", "the error never echoes what may be a key (I12)"
    assert_equal "MY_KEY", parse({ "profiles" => { "default" => BASE.merge("apiKeyEnv" => "MY_KEY") } }).profiles["default"].api_key_env
  end

  def test_fallback_must_name_another_profile
    assert_match(/cannot name itself/, error({ "profiles" => { "default" => BASE.merge("fallback" => "default") } }))
    assert_match(/no profile named "gone"/, error({ "profiles" => { "default" => BASE.merge("fallback" => "gone") } }))
  end

  def test_swap_commands_are_argv_arrays
    c = parse({ "profiles" => { "default" => BASE.merge("swap" => { "start" => %w[server start] }) } })
    assert_equal %w[server start], c.profiles["default"].swap.start
    assert_match(/swap.start: expected array of strings/, error({ "profiles" => { "default" => BASE.merge("swap" => { "start" => "server start" }) } }))
  end

  def test_env_overrides_base_url_and_model
    env = { "HARNESS_LOCAL_GPU_BASE_URL" => "http://127.0.0.1:9000/v1", "HARNESS_LOCAL_GPU_MODEL" => "picked" }
    p = parse({ "profiles" => { "local-gpu" => BASE } , "roles" => { "planner" => "local-gpu", "implementer" => "local-gpu", "reviewer" => "local-gpu" } }, env: env).profiles["local-gpu"]
    assert_equal ["http://127.0.0.1:9000/v1", "picked"], [p.base_url, p.model]
  end

  def test_load_reports_missing_and_invalid_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      assert_match(/config.json not found/, assert_raises(Harness::ParseError) { Harness::Config.load(path) }.message)
      File.write(path, "{ nope")
      assert_match(/not valid JSON/, assert_raises(Harness::ParseError) { Harness::Config.load(path) }.message)
      File.write(path, JSON.generate({ "profiles" => { "default" => BASE } }))
      assert_equal "default", Harness::Config.load(path, env: {}).profile_for(:planner).name
    end
  end

  def test_stacks_are_parsed_into_gates
    c = parse({ "profiles" => { "default" => BASE },
                "stacks" => { "astro" => { "gates" => { "typecheck" => { "argv" => %w[npx astro check], "parser" => "astro_check" } },
                                           "alwaysGates" => ["typecheck"] } } })
    assert_equal %w[npx astro check], c.stacks["astro"].gates["typecheck"].argv
    assert_match(/\Astacks.astro.gates.lint.parser: expected one of/,
                 error({ "profiles" => { "default" => BASE },
                         "stacks" => { "astro" => { "gates" => { "lint" => { "argv" => ["x"], "parser" => "pylint" } } } } }))
  end
end
