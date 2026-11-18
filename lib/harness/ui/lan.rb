# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "securerandom"
require "socket"
require_relative "../errors"

module Harness
  module UI
    # LAN mode (I15): the app can also listen on this computer's private network address, so a phone on the same
    # home network can use it. Off unless `harness ui --lan` starts it, and never saved. Only a private IPv4 address
    # (10/8, 172.16/12, 192.168/16) is accepted: never 0.0.0.0, a public address or loopback. A device pairs once
    # with a short code shown on the computer; the code expires, and wrong codes lock pairing until the computer
    # makes a new one. A paired device holds a random session cookie for this run of the app only.
    class Lan
      PRIVATE = [[0x0A000000, 8], [0xAC100000, 12], [0xC0A80000, 16]].freeze
      CODE_TTL = 600
      MAX_FAILURES = 5
      MAX_DEVICES = 8
      COOKIE = "harness_session"
      SESSION = /\A\h{64}\z/

      attr_reader :ip, :port

      # @param ip [String] a private IPv4 address of this computer
      # @param port [Integer]
      # @param clock [#call] -> Float seconds
      # @raise [ConfigError] when ip is not a private IPv4 address
      def initialize(ip:, port:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        raise ConfigError, "LAN mode needs a private network address (10.x, 172.16-31.x or 192.168.x), not #{ip.to_s[0, 40].inspect}" unless self.class.private_ipv4?(ip)

        @ip = ip
        @port = port
        @clock = clock
        @mutex = Mutex.new
        @sessions = {}
        @on = true
        new_code
      end

      # @param ip [String]
      # @return [Boolean] whether ip is a dotted IPv4 address in 10/8, 172.16/12 or 192.168/16
      def self.private_ipv4?(ip)
        parts = ip.to_s.match(/\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/)&.captures&.map(&:to_i)
        return false unless parts&.all? { |p| p <= 255 }

        n = parts.reduce(0) { |acc, p| (acc << 8) | p }
        PRIVATE.any? { |base, bits| (n >> (32 - bits)) == (base >> (32 - bits)) }
      end

      # @param addresses [Array<String>] candidate IPv4 addresses (defaults to this computer's)
      # @return [String, nil] the first private one
      def self.detect(addresses = Socket.ip_address_list.select(&:ipv4?).map(&:ip_address))
        addresses.find { |a| private_ipv4?(a) }
      end

      # @return [String] the address to open on the phone
      def url = "http://#{@ip}:#{@port}/"

      # @return [Boolean] false after stop
      def on? = @mutex.synchronize { @on }

      # A fresh pairing code; it also lifts a lock after too many wrong codes.
      # @return [String] six digits
      def new_code
        @mutex.synchronize do
          @code = format("%06d", SecureRandom.random_number(1_000_000))
          @expires = @clock.call + CODE_TTL
          @failures = 0
          @code
        end
      end

      # @param given [Object] what the phone typed
      # @return [String] a new session id for the cookie
      # @raise [ConfigError] for a wrong, expired or locked code, or too many devices
      def pair(given)
        @mutex.synchronize do
          raise ConfigError, "LAN mode is off" unless @on
          raise ConfigError, "too many wrong codes: make a new code on the computer" if @failures >= MAX_FAILURES
          raise ConfigError, "the code expired: make a new one on the computer" if @clock.call > @expires
          raise ConfigError, "#{MAX_DEVICES} devices are paired already" if @sessions.size >= MAX_DEVICES

          unless given.is_a?(String) && given.bytesize == @code.bytesize && same?(given, @code)
            @failures += 1
            raise ConfigError, "wrong code (#{MAX_FAILURES - @failures} tries left)"
          end
          @code = format("%06d", SecureRandom.random_number(1_000_000)) # one code pairs one device
          @expires = @clock.call + CODE_TTL
          id = SecureRandom.hex(32)
          @sessions[id] = true
          id
        end
      end

      # @param cookie_header [String, nil] the request's Cookie header
      # @return [Boolean] whether it carries a session this run of the app paired
      def paired?(cookie_header)
        id = cookie_header.to_s.split(/;\s*/).filter_map { |c| c.split("=", 2) }.to_h[COOKIE]
        return false unless id.is_a?(String) && id.match?(SESSION)

        @mutex.synchronize { @on && @sessions.key?(id) }
      end

      # Stop sharing: no new pairing, and every paired device is signed out.
      # @return [void]
      def stop
        @mutex.synchronize do
          @on = false
          @sessions.clear
        end
      end

      # @return [Hash] for the computer's own banner: never sent to a LAN device
      def to_json_hash
        @mutex.synchronize do
          left = (@expires - @clock.call).ceil
          { "on" => @on, "url" => url, "code" => @code, "codeSecondsLeft" => left.positive? ? left : 0,
            "locked" => @failures >= MAX_FAILURES, "devices" => @sessions.size }
        end
      end

      private

      def same?(a, b)
        a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
      end
    end
  end
end
