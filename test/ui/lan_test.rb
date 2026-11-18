# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# LAN mode (I15): only a private address, only after pairing with the computer's code, and only the allowed actions;
# the computer's own controls never answer on the LAN. The LAN listener itself is not opened here (listen_lan: false):
# requests go straight to Server#respond with via: :lan.

require_relative "../test_helper"
require "json"

class UILanTest < Minitest::Test
  Lan = Harness::UI::Lan
  Request = Harness::UI::Request
  IP = "192.168.1.20"

  # Records what reached the app.
  class FakeApp
    attr_reader :seen

    def initialize = @seen = []

    def call(req)
      @seen << [req.method, req.path]
      Harness::UI::Response.json({ "ok" => true })
    end
  end

  def setup
    @now = 0.0
    @app = FakeApp.new
    @token = "c" * 64
    @server = Harness::UI::Server.new(app: @app, port: 0, token: @token, lan: Lan.new(ip: IP, port: 1), listen_lan: false)
    @lan = @server.lan
  end

  def teardown = @server.stop

  def req(method, path, headers: {}, body: "")
    Request.new(method: method, path: path, query: {}, headers: { "host" => "#{IP}:#{@server.port}" }.merge(headers), body: body)
  end

  def lan(method, path, **opts) = @server.respond(req(method, path, **opts), via: :lan)

  def local(method, path, body: "{}")
    headers = { "host" => "127.0.0.1:#{@server.port}", "x-harness-token" => @token, "origin" => "http://127.0.0.1:#{@server.port}",
                "content-type" => "application/json" }
    @server.respond(Request.new(method: method, path: path, query: {}, headers: headers, body: body))
  end

  def origin = { "origin" => "http://#{IP}:#{@server.port}", "content-type" => "application/json" }

  def pair!
    code = JSON.parse(local("GET", "/api/lan").body)["code"]
    r = lan("POST", "/api/lan/pair", headers: origin, body: JSON.generate({ "code" => code }))
    assert_equal 200, r.status
    r.headers["Set-Cookie"][/harness_session=\h{64}/]
  end

  def test_only_private_addresses_are_accepted
    %w[10.0.0.5 172.16.0.1 172.31.255.254 192.168.1.20].each { |ip| assert Lan.private_ipv4?(ip), ip }
    %w[0.0.0.0 127.0.0.1 8.8.8.8 172.32.0.1 192.169.0.1 100.64.0.1 192.168.1 192.168.1.256 ::1 example.lan].each do |ip|
      refute Lan.private_ipv4?(ip), ip
      assert_raises(Harness::ConfigError) { Lan.new(ip: ip, port: 4567) }
    end
    assert_equal "192.168.0.7", Lan.detect(%w[127.0.0.1 8.8.8.8 192.168.0.7 10.0.0.1])
    assert_nil Lan.detect(%w[127.0.0.1 8.8.8.8])
    refute_includes File.read(File.join(TestSupport::ROOT, "lib/harness/ui/server.rb")), "0.0.0.0", "never every interface"
  end

  def test_pairing_needs_the_code_which_expires_locks_and_pairs_one_device
    lan = Lan.new(ip: IP, port: 4567, clock: -> { @now })
    code = lan.to_json_hash["code"]
    assert_match(/\A\d{6}\z/, code)
    e = assert_raises(Harness::ConfigError) { lan.pair("000000" == code ? "111111" : "000000") }
    assert_match(/wrong code \(4 tries left\)/, e.message)
    session = lan.pair(code)
    assert lan.paired?("other=1; harness_session=#{session}")
    refute lan.paired?("harness_session=#{'0' * 64}")
    refute lan.paired?(nil)
    assert_raises(Harness::ConfigError, "a code pairs one device") { lan.pair(code) }

    code = lan.new_code
    4.times { assert_raises(Harness::ConfigError) { lan.pair("x") } }
    assert_raises(Harness::ConfigError) { lan.pair("y") }
    assert_match(/too many wrong codes/, assert_raises(Harness::ConfigError) { lan.pair(code) }.message, "locked, even for the right code")
    code = lan.new_code
    @now += Lan::CODE_TTL + 1
    assert_match(/expired/, assert_raises(Harness::ConfigError) { lan.pair(code) }.message)

    lan.stop
    refute lan.paired?("harness_session=#{session}"), "stop signs every device out"
    assert_match(/off/, assert_raises(Harness::ConfigError) { lan.pair(lan.new_code) }.message)
  end

  def test_an_unpaired_device_gets_only_the_pairing_page
    r = lan("GET", "/")
    assert_equal 200, r.status
    assert_includes r.body, "Pair this device"
    refute_includes r.body, @token, "no token before pairing"
    assert_equal 200, lan("GET", "/pair.js").status
    assert_equal 401, lan("GET", "/api/state").status
    assert_equal 401, lan("POST", "/api/chats", headers: origin.merge("x-harness-token" => @token), body: "{}").status
    assert_equal 421, @server.respond(req("GET", "/").with(headers: { "host" => "127.0.0.1:#{@server.port}" }), via: :lan).status
    assert_equal 403, lan("POST", "/api/lan/pair", headers: { "origin" => "http://evil.example", "content-type" => "application/json" },
                                                 body: '{"code":"1"}').status
    refute(@app.seen.any? { |_, p| p.start_with?("/api") }, "no API call reached the app before pairing")
  end

  def test_a_paired_device_may_build_but_not_run_commands_or_change_settings
    cookie = { "cookie" => pair! }
    assert_equal 200, lan("GET", "/api/state", headers: cookie).status
    post = cookie.merge(origin).merge("x-harness-token" => @token)
    assert_equal 200, lan("POST", "/api/chats", headers: post, body: "{}").status
    assert_equal 200, lan("POST", "/api/runs/r20260101-000000-abcd/resume", headers: post, body: "{}").status
    %w[/api/settings /api/appearance /api/providers/use /api/providers/action /api/projects/link /api/projects/clone
       /api/projects/fix /api/runs/r20260101-000000-abcd/fix /api/previews/start /api/lan/stop /api/lan/code].each do |path|
      assert_equal 403, lan("POST", path, headers: post, body: "{}").status, path
    end
    %w[/api/providers /api/settings /api/doctor /api/lan /api/previews].each { |path| assert_equal 403, lan("GET", path, headers: cookie).status, path }
    assert_equal 403, lan("POST", "/api/chats", headers: cookie.merge(origin), body: "{}").status, "the token is still needed"
    refute_includes @app.seen, ["POST", "/api/settings"]
  end

  def test_the_computer_controls_lan_mode_and_stop_turns_it_off
    off = Harness::UI::Server.new(app: @app, port: 0, token: @token)
    body = off.respond(Request.new(method: "GET", path: "/api/lan", query: {},
                                   headers: { "host" => "127.0.0.1:#{off.port}" }, body: ""))
    assert_equal({ "on" => false }, JSON.parse(body.body))
    off.stop

    view = JSON.parse(local("GET", "/api/lan").body)
    assert_equal [true, "http://#{IP}:#{@server.port}/", false, 0], view.values_at("on", "url", "locked", "devices")
    cookie = { "cookie" => pair! }
    assert_equal 1, JSON.parse(local("GET", "/api/lan").body)["devices"]
    old = JSON.parse(local("GET", "/api/lan").body)["code"]
    refute_equal old, JSON.parse(local("POST", "/api/lan/code").body)["code"]
    assert_equal({ "on" => false }, JSON.parse(local("POST", "/api/lan/stop").body))
    assert_equal 403, lan("GET", "/api/state", headers: cookie).status, "after Stop sharing nothing answers on the LAN"
    assert_equal 403, lan("GET", "/").status
  end
end
