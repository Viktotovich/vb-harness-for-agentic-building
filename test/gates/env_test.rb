# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"

class EnvTest < Minitest::Test
  E = Harness::Gates::Env

  def test_only_the_base_node_and_allowed_names_pass
    parent = { "Path" => "/bin", "HOME" => "/home-placeholder", "NODE_ENV" => "test", "NODE_OPTIONS" => "--x",
               "NODE_AUTH_TOKEN" => "t", "GITHUB_TOKEN" => "t", "EDITOR" => "vi", "MY_API_KEY" => "k" }
    env = E.build(parent)
    assert_equal({ "PATH" => "/bin", "HOME" => "/home-placeholder", "NODE_ENV" => "test", "CI" => "1",
                   "npm_config_yes" => "false" }, env)
  end

  def test_gate_env_allow_passes_names_even_when_they_look_secret
    env = E.build({ "MY_API_KEY" => "k", "NODE_OPTIONS" => "--max-old-space-size=4096" }, allow: %w[MY_API_KEY NODE_OPTIONS])
    assert_equal "k", env["MY_API_KEY"]
    assert_equal "--max-old-space-size=4096", env["NODE_OPTIONS"]
  end

  def test_fixed_values_cannot_be_overridden_by_the_parent
    env = E.build({ "CI" => "0", "npm_config_yes" => "true" }, allow: %w[CI npm_config_yes])
    assert_equal %w[1 false], [env["CI"], env["npm_config_yes"]], "npx must never auto-install (I10)"
  end
end
