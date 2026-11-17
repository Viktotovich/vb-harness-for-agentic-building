# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Settings · Appearance: the mode and the colours of each look, validated before they are saved, and served as
# /theme.css built from hex values only (the strict CSP holds and nothing typed becomes CSS syntax).

require_relative "../test_helper"
require_relative "../support/ui_client"
require "json"
require "tmpdir"

class UIAppearanceTest < Minitest::Test
  A = Harness::UI::Appearance
  C = TestSupport::UIClient

  def setup
    @tmp = Dir.mktmpdir("harness-ui-look-")
    @token = "b" * 64
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def test_parse_accepts_a_mode_and_known_colours_only
    look = A.parse({ "mode" => "dark", "dark" => { "accent" => "#ABCDEF" }, "light" => {} })
    assert_equal ["dark", { "accent" => "#abcdef" }, {}], [look.mode, look.dark, look.light]
    assert_equal A::DEFAULT, A.parse({})
    {
      { "mode" => "sepia" } => /appearance.mode: expected one of system, dark, light/,
      { "dark" => { "font" => "#ffffff" } } => /appearance.dark.font: unknown colour/,
      { "light" => { "bg" => "red" } } => /appearance.light.bg: expected a colour like/,
      { "light" => { "bg" => "#fff;}body{" } } => /appearance.light.bg: expected a colour/,
      { "dark" => "#000000" } => /appearance.dark: expected an object of colours/,
      { "font" => "x" } => /appearance.font: unknown field/,
      [] => /expected an object/
    }.each { |bad, message| assert_raises(Harness::ParseError) { A.parse(bad) }.then { |e| assert_match(message, e.message) } }
  end

  def test_css_keeps_each_look_in_its_own_selectors
    css = A.css(A.parse({ "mode" => "system", "dark" => { "bg" => "#101010", "accent" => "#f0f0f0" }, "light" => { "text" => "#202020" } }))
    assert_match(/:root \{\n  --bg: #101010;\n  --accent: #f0f0f0;\n  --on-accent: #16151c;\n\}/, css)
    assert_includes css, %(@media (prefers-color-scheme: light) {\n:root:not([data-mode="dark"]) {\n  --text: #202020;\n}\n}\n)
    assert_includes css, %(:root[data-mode="light"] {\n  --text: #202020;\n}\n)
    assert_equal 1, A.css(A::DEFAULT).lines.size, "no colours chosen: only the comment"
    assert_equal "#ffffff", A.on_accent("#3a2a8a"), "a dark accent gets white text"
    assert_equal "#16151c", A.on_accent("#e0dcff")
  end

  def test_the_app_saves_the_choice_and_serves_it
    home = File.join(@tmp, "home")
    FileUtils.mkdir_p(home)
    app = Harness::UI::App.new(config_path: File.join(home, "config.json"), token: @token, env: ENV.to_h, pipeline_for: ->(*) { raise "no runs here" })
    @server = Harness::UI::Server.new(app: app, port: 0, token: @token)
    @server.start
    port = @server.port
    assert_includes C.request(port, "GET", "/").body, '<html lang="en" data-mode="system">', "works before any model is set up"
    assert_equal({ "mode" => "system", "dark" => {}, "light" => {} }, C.request(port, "GET", "/api/appearance").json)

    assert_equal 403, C.request(port, "POST", "/api/appearance", body: { "mode" => "light" }).status, "a change needs the token"
    assert_equal 400, C.post(port, @token, "/api/appearance", { "mode" => "light", "light" => { "bg" => "url(x)" } }).status
    refute File.exist?(File.join(home, "appearance.json")), "nothing is written for a bad choice"

    saved = C.post(port, @token, "/api/appearance", { "mode" => "light", "light" => { "accent" => "#2F6F9F" } }).json
    assert_equal({ "mode" => "light", "dark" => {}, "light" => { "accent" => "#2f6f9f" } }, saved)
    assert_equal saved, JSON.parse(File.read(File.join(home, "appearance.json")))
    assert_includes C.request(port, "GET", "/").body, 'data-mode="light"'
    css = C.request(port, "GET", "/theme.css")
    assert_equal "text/css; charset=utf-8", css.headers["content-type"]
    assert_includes css.body, "--accent: #2f6f9f;"
    assert_equal saved, C.request(port, "GET", "/api/state").json["appearance"]

    File.write(File.join(home, "appearance.json"), "{not json")
    assert_includes C.request(port, "GET", "/").body, 'data-mode="system"', "a broken file falls back to the default"
  end
end
