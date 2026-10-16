# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# The app's API: chats, model switching, streamed Chat replies, Build runs with SSE replay from a seq, answers,
# the report, and provider onboarding against fake servers and fake lms and ollama tools.

require_relative "../test_helper"
require_relative "../support/review_run"
require_relative "../support/ui_client"
require "json"
require "tmpdir"

class UIAppTest < Minitest::Test
  C = TestSupport::UIClient
  F = TestSupport::RunFixture
  RR = TestSupport::ReviewRun
  Fake = TestSupport::FakeLlmServer
  # Stands in for lms and ollama: answers the fixed subcommands.
  FAKE_CLI = <<~RUBY
    case ARGV.join(" ")
    when "ls --json" then puts '[{"modelKey":"local/coder-7b"},{"modelKey":"bad key"}]'
    when /\\Aload / then puts "loaded \#{ARGV.last}"
    when /\\Apull / then puts "pulled \#{ARGV.last}"
    when "server start" then puts "server started"
    else puts "ran \#{ARGV.join(' ')}"
    end
  RUBY

  def setup
    @tmp = Dir.mktmpdir("harness-ui-app-")
    @home = File.join(@tmp, "home")
    FileUtils.mkdir_p(@home)
    @token = "a" * 64
  end

  def teardown
    @server&.stop
    [@model, @lms, @ollama].compact.each(&:stop)
    FileUtils.rm_rf(@tmp)
  end

  def start(config: nil, env: ENV.to_h, clis: {}, urls: { "lmstudio" => "http://127.0.0.1:9/v1", "ollama" => "http://127.0.0.1:9" })
    File.write(File.join(@home, "config.json"), JSON.generate(config)) if config
    factory = lambda do |cfg, home|
      Harness::Pipeline.new(config: cfg, home: home, env: env, client_factory: ->(store) { F.client(cfg, store) })
    end
    app = Harness::UI::App.new(config_path: File.join(@home, "config.json"), token: @token, env: env, pipeline_for: factory,
                               clis: clis, urls: urls)
    @server = Harness::UI::Server.new(app: app, port: 0, token: @token)
    @server.start
    @port = @server.port
  end

  def post(path, body = {}) = C.post(@port, @token, path, body)
  def get(path) = C.request(@port, "GET", path)

  def sse_reply(*pieces)
    lines = pieces.map { |delta| "data: #{JSON.generate({ 'choices' => [{ 'delta' => delta }] })}\n\n" }
    [200, "#{lines.join}data: #{JSON.generate({ 'choices' => [{ 'delta' => {}, 'finish_reason' => 'stop' }] })}\n\ndata: [DONE]\n\n"]
  end

  def test_chats_rename_delete_and_model_switch
    @model = Fake.new(models: [{ "id" => "model-a" }, { "id" => "model-b" }])
    start(config: RR.raw_config(@model.base_url))
    state = get("/api/state").json
    assert_equal ["default · model-a", "default · model-b"], state["models"].map { |m| m["label"] }
    assert_equal "claim refuted by code", state["reasons"]["verify.refuted_by_code"]
    chat = post("/api/chats", { "model" => { "profile" => "default", "model" => "model-a" } }).json
    id = chat["id"]
    assert_equal({ "profile" => "default", "model" => "model-a" }, chat["model"])
    assert_equal "Pricing", post("/api/chats/#{id}/rename", { "title" => " Pricing " }).json["title"]
    post("/api/chats/#{id}/send", { "text" => "hello", "mode" => "chat" })
    switched = post("/api/chats/#{id}/model", { "profile" => "default", "model" => "model-b" }).json
    assert_equal "Model switched to default · model-b", switched["messages"].last["content"]
    assert_equal 400, post("/api/chats/#{id}/model", { "profile" => "nope", "model" => "x" }).status
    assert_equal [id], get("/api/chats").json.map { |c| c["id"] }
    assert_equal 200, post("/api/chats/#{id}/delete").status
    assert_empty get("/api/chats").json
    assert_equal 404, get("/api/chats/#{id}").status
    assert_equal 404, get("/api/chats/..%2Fconfig").status
  end

  def test_a_chat_reply_streams_text_and_thinking_and_is_saved
    @model = Fake.new { |_body, _n| sse_reply({ "reasoning_content" => "Let me think." }, { "content" => "Hel" }, { "content" => "lo <thi" }, { "content" => "nk>inline</think>!" }) }
    start(config: RR.raw_config(@model.base_url))
    id = post("/api/chats", {}).json["id"]
    stream = post("/api/chats/#{id}/send", { "text" => "Say hello", "mode" => "chat" }).json["stream"]
    events = get("/api/streams/#{stream}").events
    assert_equal "Hello !", events.select { |e, _| e == "text" }.map { |_, d| d["text"] }.join
    assert_equal "Let me think.inline", events.select { |e, _| e == "thinking" }.map { |_, d| d["text"] }.join
    assert_equal ["done", { "finish" => "stop" }], events.last
    chat = get("/api/chats/#{id}").json
    assert_equal "Say hello", chat["title"]
    assert_equal [%w[user Say\ hello], ["assistant", "Hello !"]], chat["messages"].map { |m| [m["role"], m["content"]] }
    assert_equal "Let me think.inline", chat["messages"].last["thinking"]
    body = @model.chat_bodies.last
    assert body["stream"]
    assert_equal %w[system user], body["messages"].map { |m| m["role"] }
  end

  def test_old_messages_become_a_summary_when_the_context_is_small
    @model = Fake.new do |body, _n|
      if body["messages"].first["content"].start_with?("You summarize")
        sse_reply({ "content" => "Earlier: they talked about prices." })
      else
        sse_reply({ "content" => "ok" })
      end
    end
    cfg = RR.raw_config(@model.base_url)
    cfg["profiles"]["default"].merge!("contextTokens" => 2048, "maxOutputTokens" => 500)
    start(config: cfg)
    id = post("/api/chats", {}).json["id"]
    3.times do |i|
      stream = post("/api/chats/#{id}/send", { "text" => "message #{i} #{'x' * 900}", "mode" => "chat" }).json["stream"]
      get("/api/streams/#{stream}")
    end
    last = @model.chat_bodies.reverse.find { |b| !b["messages"].first["content"].start_with?("You summarize") }
    assert_includes last["messages"][1]["content"], "Summary of the earlier conversation:\nEarlier: they talked about prices."
    assert_includes last["messages"].last["content"], "message 2"
    refute(last["messages"].any? { |m| m["content"].include?("message 0") }, "the oldest message is summarised, not sent")
    assert_equal "Earlier: they talked about prices.", get("/api/chats/#{id}").json.dig("summary", "text")
  end

  def test_a_build_streams_its_events_replays_from_a_seq_and_shows_the_report
    task = F.task("T1", "Double the price", modify: ["src/lib/price.ts"])
    @model = F.server({ "plan" => [F.plan_reply([task], questions: [{ "text" => "Which currency?", "blocking" => true }]),
                                   F.plan_reply([task])],
                        "T1 implement" => F.replace("src/lib/price.ts", "  return n;", "  return n * 2;") })
    repo, git_env = TestSupport.repo(@tmp, RR::FILES)
    start(config: RR.raw_config(@model.base_url), env: ENV.to_h.merge(git_env))
    id = post("/api/chats", {}).json["id"]
    assert_equal 404, post("/api/chats/#{id}/send", { "text" => "Double it", "mode" => "build", "project" => "nope" }).status
    linked = post("/api/projects/link", { "path" => repo }).json
    assert_equal ["repo", true, true, "main", "astro"], linked.values_at("name", "linked", "clean", "branch", "stack")
    sent = post("/api/chats/#{id}/send", { "text" => "Double the price.", "mode" => "build", "project" => "repo" })
    run = sent.json["run"]
    assert run, sent.body
    assert_match(/\Ar\d{8}-\d{6}-\h{4}\z/, run)
    first = get("/api/runs/#{run}/events?after=0").events
    waiting = first.select { |e, _| e == "run" }.last[1]
    assert_equal ["waiting", ["Which currency?"]], waiting.values_at("status", "questions")
    assert_equal ["end", { "status" => "waiting" }], first.last
    seqs = first.select { |e, _| e == "event" }.map { |_, d| d["seq"] }
    assert_equal (1..seqs.size).to_a, seqs
    assert_equal 403, C.request(@port, "POST", "/api/runs/#{run}/answer", body: { "answers" => ["USD"] }).status, "answers need the token"
    assert_equal 400, post("/api/runs/#{run}/answer", { "answers" => %w[USD EUR] }).status
    assert_equal 200, post("/api/runs/#{run}/answer", { "answers" => ["USD"] }).status
    rest = get("/api/runs/#{run}/events?after=#{seqs.last}").events
    assert(rest.select { |e, _| e == "event" }.all? { |_, d| d["seq"] > seqs.last }, "replay starts after the given seq")
    assert_equal ["end", { "status" => "done" }], rest.last
    run_event = rest.select { |e, _| e == "run" }.last[1]
    assert_equal [{ "id" => "T1", "title" => "Double the price", "dependsOn" => [] }], run_event["tasks"]
    done = rest.find { |e, d| e == "event" && d["kind"] == "done" && d["subject"] == "task" }
    assert done, "the task's done event streams"
    with_reason = (first + rest).select { |e, d| e == "event" && d["reason"] }
    assert(with_reason.all? { |_, d| d["reasonText"].is_a?(String) && !d["reasonText"].empty? }, "every reason comes with its human text")
    report = get("/api/runs/#{run}/report")
    assert_match(%r{\Atext/markdown}, report.headers["content-type"])
    assert_includes report.body, "## Findings"
    chat = get("/api/chats/#{id}").json
    assert_equal [["user", "build"], ["build", nil]], chat["messages"].map { |m| [m["role"], m["mode"]] }
    assert_equal "repo", chat["messages"].last["project"]
    refute(chat["messages"].any? { |m| m.key?("repo") }, "chats name the project, never its absolute path")
    assert_equal 404, get("/api/runs/..%2F..%2Fsecret/report").status
  end

  def test_provider_onboarding_with_fake_servers_and_tools
    @lms = Fake.new(models: [])
    @ollama = Fake.new(routes: { "/api/tags" => [200, { "models" => [{ "name" => "coder:7b" }] }] }, models: [{ "id" => "coder:7b" }])
    script = File.join(@tmp, "fake_cli.rb")
    File.write(script, FAKE_CLI)
    clis = { "lms" => [RbConfig.ruby, script], "ollama" => [RbConfig.ruby, script] }
    start(clis: clis, urls: { "lmstudio" => @lms.base_url, "ollama" => @ollama.base_url.delete_suffix("/v1") })
    refute get("/api/state").json["configured"]
    found = get("/api/providers").json
    assert_equal [["lmstudio", true, [], "no model is loaded", true], ["ollama", true, ["coder:7b"], nil, true]],
                 found.map { |p| p.values_at("kind", "up", "models", "error", "cli") }
    ls = post("/api/providers/action", { "kind" => "lmstudio", "action" => "ls" }).json
    assert_equal ["local/coder-7b"], ls["models"], "names that fail the check never reach a button"
    assert_equal "loaded local/coder-7b", post("/api/providers/action", { "kind" => "lmstudio", "action" => "load", "model" => "local/coder-7b" }).json["output"]
    assert_equal "pulled coder:7b", post("/api/providers/action", { "kind" => "ollama", "action" => "pull", "model" => "coder:7b" }).json["output"]
    assert_equal 400, post("/api/providers/action", { "kind" => "ollama", "action" => "pull", "model" => "x; rm -rf ~" }).status
    used = post("/api/providers/use", { "kind" => "ollama", "model" => "coder:7b" }).json
    assert_equal ["ollama", "coder:7b"], used.values_at("profile", "model")
    assert_match(/\A\d+K context, JSON mode: (?:yes|no), tools: (?:yes|no), thinking can(?:not)? be turned off\z/, used["summary"])
    cfg = JSON.parse(File.read(File.join(@home, "config.json")))
    assert_equal({ "baseUrl" => "#{@ollama.base_url}", "model" => "coder:7b" }, cfg["profiles"]["ollama"].slice("baseUrl", "model"))
    assert(cfg["roles"].values.all?("ollama"), "the first provider takes every role")
    assert get("/api/state").json["configured"]
    custom = post("/api/providers/custom", { "baseUrl" => @lms.base_url, "keyEnv" => "sk-123" })
    assert_equal 400, custom.status, "a key typed where the env var name goes is refused"
    assert_equal 400, post("/api/providers/use", { "kind" => "custom", "baseUrl" => "file:///etc", "model" => "m" }).status
  end
end
