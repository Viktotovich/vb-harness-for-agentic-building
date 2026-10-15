# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# I15: the app listens on 127.0.0.1 only, refuses foreign Host headers, needs the token and its own Origin for every
# state change, sends a strict CSP and no CORS, and never renders model output as HTML.

require_relative "../test_helper"
require_relative "../support/ui_client"
require "tmpdir"

class UIServerTest < Minitest::Test
  C = TestSupport::UIClient
  PUBLIC = File.join(TestSupport::ROOT, "lib", "harness", "ui", "public")

  def setup
    @tmp = Dir.mktmpdir("harness-ui-")
    @token = "t" * 64
    app = Harness::UI::App.new(config_path: File.join(@tmp, "config.json"), token: @token, env: { "PATH" => "" },
                               pipeline_for: ->(*) { raise "no builds here" }, urls: { "lmstudio" => "http://127.0.0.1:9/v1", "ollama" => "http://127.0.0.1:9" })
    @server = Harness::UI::Server.new(app: app, port: 0, token: @token)
    @server.start
    @port = @server.port
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@tmp)
  end

  def test_it_listens_on_loopback_only
    assert_equal "127.0.0.1", Harness::UI::Server::HOST
    assert_equal "http://127.0.0.1:#{@port}/", @server.url
    refute_includes File.read(File.join(TestSupport::ROOT, "lib/harness/ui/server.rb")), "0.0.0.0"
  end

  def test_the_page_carries_the_token_and_a_strict_csp
    r = C.request(@port, "GET", "/")
    assert_equal 200, r.status
    assert_includes r.body, %(<meta name="harness-token" content="#{@token}">)
    assert_equal Harness::UI::Server::CSP, r.headers["content-security-policy"]
    %w[default-src\ 'self' script-src\ 'self' frame-ancestors\ 'none' form-action\ 'none'].each { |d| assert_includes r.headers["content-security-policy"], d }
    assert_equal "nosniff", r.headers["x-content-type-options"]
    refute(r.headers.keys.any? { |k| k.start_with?("access-control-") }, "no CORS headers")
    assert_equal "font/woff2", C.request(@port, "GET", "/fonts/InterVariable.woff2").headers["content-type"]
    assert_equal 404, C.request(@port, "GET", "/../config.json").status
  end

  def test_foreign_hosts_are_refused
    ["evil.example:#{@port}", "127.0.0.1:1", "localhost", "", "127.0.0.1.nip.io:#{@port}"].each do |host|
      assert_equal 421, C.request(@port, "GET", "/api/state", headers: { "Host" => host }).status, host.inspect
    end
    assert_equal 200, C.request(@port, "GET", "/api/state", headers: { "Host" => "localhost:#{@port}" }).status
  end

  def test_state_changes_need_the_token_and_the_apps_origin
    origin = "http://127.0.0.1:#{@port}"
    json = { "Content-Type" => "application/json" }
    assert_equal 403, C.request(@port, "POST", "/api/chats", body: {}, headers: json.merge("Origin" => origin)).status, "no token"
    assert_equal 403, C.request(@port, "POST", "/api/chats", body: {}, headers: json.merge("Origin" => origin, "X-Harness-Token" => "x" * 64)).status
    assert_equal 403, C.request(@port, "POST", "/api/chats", body: {}, headers: json.merge("X-Harness-Token" => @token)).status, "no Origin"
    assert_equal 403, C.request(@port, "POST", "/api/chats", body: {}, headers: json.merge("X-Harness-Token" => @token, "Origin" => "http://evil.example")).status
    assert_equal 400, C.request(@port, "POST", "/api/chats", body: {}, headers: { "X-Harness-Token" => @token, "Origin" => origin, "Content-Type" => "text/plain" }).status
    assert_equal 405, C.request(@port, "DELETE", "/api/chats").status
    created = C.post(@port, @token, "/api/chats", {})
    assert_equal 200, created.status
    assert_match(/\Ac\d{8}-\d{6}-\h{6}\z/, created.json["id"])
  end

  def test_there_is_no_route_that_runs_a_command
    r = C.post(@port, @token, "/api/providers/action", { "kind" => "ollama", "action" => "run", "model" => "x" })
    assert_equal 400, r.status
    assert_equal 404, C.post(@port, @token, "/api/exec", { "cmd" => "ls" }).status
    assert_equal 404, C.post(@port, @token, "/api/shell", { "cmd" => "ls" }).status
  end

  def test_the_page_never_parses_model_output_as_html
    js = File.read(File.join(PUBLIC, "app.js"))
    %w[innerHTML outerHTML insertAdjacentHTML document.write eval( new\ Function DOMParser createContextualFragment srcdoc].each do |sink|
      refute_includes js, sink, "app.js must not use #{sink}"
    end
    assert_includes js, "textContent"
    html = File.read(File.join(PUBLIC, "index.html"))
    refute_match(/<script(?![^>]*\bsrc=)/, html, "no inline scripts (the CSP forbids them anyway)")
    refute_match(/\son\w+=/, html, "no inline event handlers")
    refute_match(%r{https?://(?!127\.0\.0\.1)}, html + File.read(File.join(PUBLIC, "app.css")), "no external files: no CDN")
  end

  def test_model_output_cannot_start_actions
    js = File.read(File.join(PUBLIC, "app.js"))
    # Every POST in the page sits in a handler of a click, the text box or a change of the picker; none is called while
    # rendering a message.
    render = js[/function messageNode.*?\n  }\n/m] + js[/function markdown.*?\n  }\n/m] + js[/function inline.*?\n  }\n/m]
    refute_includes render, "post(", "rendering a message never sends anything"
    refute_includes render, "fetch(", "rendering a message never calls the server"
  end
end
