# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# harness init with scripted answers (the REVIEWER wizard's tests, adapted).

require_relative "../test_helper"
require_relative "../support/fake_llm_server"
require_relative "../support/review_fixture"
require "json"
require "tmpdir"

class InitTest < Minitest::Test
  Fake = TestSupport::FakeLlmServer
  Input = Struct.new(:lines) do
    def gets = lines.shift
  end

  def setup
    @tmp = Dir.mktmpdir("harness-init-")
    @path = File.join(@tmp, "config.json")
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def init(answers, env: {})
    out = TestSupport::Sink.new
    code = Harness::CLI::Init.new(input: Input.new(answers.map { |a| "#{a}\n" }), out: out, path: @path, env: env,
                                  detect: @detect || -> { [] }).call
    [code, out.string]
  end

  def test_lists_the_servers_models_and_writes_a_valid_config
    @server = Fake.new(models: [{ "id" => "first-model" }, { "id" => "second-model" }])
    docs = TestSupport::ReviewFixture.docs(File.join(@tmp, "docs"))
    code, out = init([@server.base_url, "", "2", "16384", docs, "y"])
    assert_equal 0, code, out
    assert_includes out, "  2) second-model"
    assert_includes out, "  3) auto (whichever model the server has loaded at run time)"
    cfg = JSON.parse(File.read(@path))
    p = cfg["profiles"]["default"]
    assert_equal [@server.base_url, "second-model", 16_384, nil], p.values_at("baseUrl", "model", "contextTokens", "apiKeyEnv")
    assert_equal docs, cfg.dig("stacks", "astro", "docs", "local")
    assert Harness::Config.parse(cfg)
  end

  def test_bad_answers_are_asked_again_and_keys_are_never_typed
    @server = Fake.new(models: [{ "id" => "m" }])
    code, out = init(["ftp://x", @server.base_url, "sk-not-a-name", "MY_KEY", "2", "lots", "probe", "/no/such/docs", "", "maybe", "y"],
                     env: { "MY_KEY" => "secret-value" })
    assert_equal 0, code, out
    assert_includes out, "an http(s) URL"
    assert_includes out, "an env var name such as MY_SERVER_KEY, not the key itself"
    assert_includes out, "a number, or probe"
    assert_includes out, "no src/content/docs/en there"
    assert_includes out, "answer y or n"
    cfg = JSON.parse(File.read(@path))
    assert_equal ["auto", "probe", "MY_KEY"], cfg["profiles"]["default"].values_at("model", "contextTokens", "apiKeyEnv")
    refute_includes File.read(@path), "secret-value", "I12: the key is never written"
    assert_equal "Bearer secret-value", @server.requests.first.headers["authorization"], "the key is sent to list models"
    refute_includes out, "secret-value"
  end

  def test_an_unreachable_server_asks_for_the_id_and_no_keeps_the_file_unwritten
    code, out = init(["http://127.0.0.1:9/v1", "", "my-model", "probe", "", "n"])
    assert_equal 1, code
    assert_includes out, "Could not reach the server"
    refute File.exist?(@path)
  end

  def test_a_detected_provider_is_the_default_url
    @server = Fake.new(models: [{ "id" => "local-model" }])
    @detect = -> { [Harness::Providers::Provider.new(kind: "lmstudio", label: "LM Studio", base_url: @server.base_url, up: true,
                                                     models: ["local-model"], cli: nil, error: nil)] }
    code, out = init(["", "", "1", "probe", "", "y"])
    assert_equal 0, code, out
    assert_includes out, "Found LM Studio at #{@server.base_url} (1 models)"
    assert_equal [@server.base_url, "local-model"], JSON.parse(File.read(@path))["profiles"]["default"].values_at("baseUrl", "model")
  end

  def test_existing_values_are_the_defaults_and_end_of_input_cancels
    File.write(@path, JSON.generate(JSON.parse(File.read(Harness::CLI::Init::EXAMPLE)).tap { |c| c["profiles"]["default"]["baseUrl"] = "http://127.0.0.1:9/v1" }))
    _code, out = init(["y", "", "", "kept-model", "", "", "y"])
    assert_includes out, "Server URL [http://127.0.0.1:9/v1]"
    assert_equal "kept-model", JSON.parse(File.read(@path))["profiles"]["default"]["model"]
    err = TestSupport::Sink.new
    assert_equal 2, Harness::CLI.run(["init", "--config", @path], out: TestSupport::Sink.new, err: err, input: Input.new([]))
    assert_match(/cancelled/, err.string)
  end
end
