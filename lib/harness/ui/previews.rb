# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "socket"
require_relative "../errors"
require_relative "../exec"

module Harness
  module UI
    # Preview: a project's own dev server (the stack's "preview" argv, e.g. astro dev), on a free port on 127.0.0.1,
    # for the project itself or for a build's worktree, so the user can open what was built. The command comes from
    # config only; the port is the one placeholder. Only the computer running the harness can start one, and every
    # preview stops with the app.
    class Previews
      MAX = 3
      HOST = "127.0.0.1"
      # Terminal colour codes in a dev server's output.
      ANSI = /\e\[[0-9;]*[A-Za-z]/

      # @param starter [#call] (argv, chdir:, env:) -> Exec::Background (tests pass a fake)
      # @param free_port [#call] -> Integer
      def initialize(starter: ->(argv, chdir:, env:) { Exec.start(argv, chdir: chdir, env: env) }, free_port: -> { Previews.free_port })
        @starter = starter
        @free_port = free_port
        @running = {}
        @mutex = Mutex.new
      end

      # @return [Integer] a port no one listens on right now
      def self.free_port
        s = TCPServer.new(HOST, 0)
        s.addr[1]
      ensure
        s&.close
      end

      # @param key [String] what is previewed: "project:<name>" or "run:<id>"
      # @param argv [Array<String>] the stack's preview argv with {port}
      # @param chdir [String] the folder to serve
      # @param env [Hash{String=>String}] a scrubbed environment
      # @param label [String] for people
      # @return [Hash] the preview, as #list shows it
      # @raise [ConfigError] when too many previews run already
      def start(key, argv:, chdir:, env:, label:)
        @mutex.synchronize do
          cur = @running[key]
          return view(key, cur) if cur && cur[:process].alive?

          @running.delete(key)
          raise ConfigError, "#{MAX} previews are running already: stop one first" if @running.size >= MAX

          port = @free_port.call
          process = @starter.call(argv.map { |a| a == "{port}" ? port.to_s : a }, chdir: chdir, env: env)
          @running[key] = { process: process, port: port, label: label }
          view(key, @running[key])
        end
      end

      # @param key [String]
      # @return [Boolean] whether one was running
      def stop(key)
        entry = @mutex.synchronize { @running.delete(key) }
        entry&.fetch(:process)&.stop
        !entry.nil?
      end

      # @return [void]
      def stop_all
        @mutex.synchronize { @running.keys }.each { |k| stop(k) }
      end

      # @return [Array<Hash>] every preview: key, label, url, whether it answers yet, alive, and the end of its output
      def list
        @mutex.synchronize { @running.map { |k, e| view(k, e) } }
      end

      private

      def view(key, entry)
        url = "http://#{HOST}:#{entry[:port]}/"
        { "key" => key, "label" => entry[:label], "url" => url, "alive" => entry[:process].alive?,
          "ready" => entry[:process].alive? && answering?(entry[:port]),
          "output" => entry[:process].output.gsub(ANSI, "").lines.last(12).join }
      end

      def answering?(port)
        Socket.tcp(HOST, port, connect_timeout: 0.3, &:close)
        true
      rescue SystemCallError, SocketError, IOError
        false
      end
    end
  end
end
