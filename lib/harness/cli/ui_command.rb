# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "optparse"
require "securerandom"
require_relative "../errors"
require_relative "../exec"
require_relative "../ui/app"
require_relative "../ui/server"
require_relative "commands"

module Harness
  module CLI
    # harness ui [--port 4567]: the local app on 127.0.0.1 (DESIGN.md 11.3). `harness` with no arguments runs it,
    # and opens the default browser on first start (no config.json yet, section 11.2).
    module UICommand
      USAGE = "Usage: harness ui [--port 4567] [--config FILE] [--no-open]"

      # @param args [Array<String>]
      # @param out [IO]
      # @param err [IO]
      # @param env [Hash{String=>String}]
      # @param serve [Boolean] false returns right after start (tests)
      # @return [Integer] exit code
      def self.call(args, out:, err:, env:, serve: true)
        opts = { port: 4567, config: "config.json", open: nil }
        OptionParser.new do |o|
          o.banner = USAGE
          o.on("--port PORT", Integer, "Port on 127.0.0.1 (default 4567)") { |v| opts[:port] = v }
          o.on("--config FILE", "Config file; chats/ and runs/ live next to it (default config.json)") { |v| opts[:config] = v }
          o.on("--[no-]open", "Open the browser (default: only on first start)") { |v| opts[:open] = v }
        end.parse(args)
        first = !File.file?(opts[:config])
        token = SecureRandom.hex(32)
        app = UI::App.new(config_path: opts[:config], token: token, env: env,
                          pipeline_for: ->(config, home, run_env = env) { Commands.pipeline_for(config, home, run_env, Silent.new) })
        server = UI::Server.new(app: app, port: opts[:port], token: token, log: ->(msg) { err.puts(msg) })
        out.puts "harness app: #{server.url} (Ctrl+C stops it)"
        open_browser(server.url, env, err) if opts[:open] || (opts[:open].nil? && first)
        return server unless serve

        trap("INT") { server.stop }
        server.run
        0
      rescue ParseError, ConfigError => e
        err.puts "harness ui: #{e.message}"
        2
      rescue SystemCallError => e
        err.puts "harness ui: cannot listen on 127.0.0.1:#{opts[:port]} (#{e.message})"
        2
      end

      # A fixed argv per platform; the URL is the app's own (I3).
      # @return [void]
      def self.open_browser(url, env, err)
        argv = if Exec.windows? then ["rundll32", "url.dll,FileProtocolHandler", url]
               elsif RUBY_PLATFORM.include?("darwin") then ["open", url]
               else ["xdg-open", url]
               end
        Exec.run(argv, chdir: Dir.pwd, env: env.to_h, timeout: 10)
      rescue CommandNotFoundError, UnsafeArgumentError
        err.puts "Open #{url} in your browser."
      end

      # Progress lines of builds started from the app go to the log files only.
      class Silent
        # @return [nil]
        def puts(*) = nil

        # @return [nil]
        def print(*) = nil

        # @return [nil]
        def write(*) = nil
      end
    end
  end
end
