# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"
require "rbconfig"
require "socket"
require_relative "config"
require_relative "errors"
require_relative "report/render"
require_relative "repo/git"
require_relative "state/run_store"

module Harness
  # harness demo and the app's Try the demo: a whole run with no model and no setup. A tiny bundled project (its
  # check is a Ruby script, so no Node is needed) and a scripted model server on 127.0.0.1 that answers each role
  # the way a good model would: a plan of two tasks, a first edit that fails the check, the fix, and a review that
  # finds nothing. Everything else is the real pipeline, so the report, the events and the branch are real.
  module Demo
    REQUEST = "Make price() return twice the amount, and add a total() helper in src/total.ts that adds tax " \
              "using the rate in src/tax.ts."
    MODEL = "scripted-demo"
    MARKER = "harness-demo.json"

    # The project's own check: an error for every line marked BROKEN, in the type checker's format.
    CHECK = <<~RUBY
      bad = Dir.glob("src/**/*.ts").sort.flat_map do |f|
        File.readlines(f).each_with_index.filter_map do |line, i|
          "\#{f}:\#{i + 1}:3 - error ts(2322): Type 'string' is not assignable to type 'number'." if line.include?("BROKEN")
        end
      end
      puts bad
      exit(bad.empty? ? 0 : 1)
    RUBY

    FILES = {
      MARKER => %({"about": "The project vb-harness builds in its demo. Safe to delete."}\n),
      "README.md" => "# Demo shop\n\nA tiny project for `harness demo`.\n",
      ".gitignore" => "node_modules/\n",
      "src/price.ts" => "export function price(n: number): number {\n  return n;\n}\n",
      "src/tax.ts" => "export const rate = 0.2;\n",
      "tools/check.rb" => CHECK
    }.freeze

    TOTAL = <<~TS
      import { price } from "./price";
      import { rate } from "./tax";

      export function total(n: number): number {
        return price(n) * (1 + rate);
      }
    TS

    PLAN = {
      "tasks" => [
        { "id" => "T1", "title" => "Double the price", "intent" => "price(n) returns n * 2.",
          "files" => { "modify" => ["src/price.ts"] }, "dependsOn" => [],
          "acceptance" => [{ "kind" => "gate", "gate" => "check" }] },
        { "id" => "T2", "title" => "Add total() with tax", "intent" => "src/total.ts exports total(n) = price(n) * (1 + rate).",
          "files" => { "create" => ["src/total.ts"], "read" => ["src/price.ts", "src/tax.ts"] }, "dependsOn" => ["T1"],
          "acceptance" => [{ "kind" => "gate", "gate" => "check" }] }
      ],
      "questions" => []
    }.freeze

    # The scripted answer for each step: the first T1 edit fails the check on purpose, so the demo shows a fix round.
    REPLIES = {
      "plan" => PLAN,
      "T1 implement" => { "edits" => [{ "op" => "replace", "path" => "src/price.ts", "search" => "  return n;",
                                        "replace" => "  return `${n * 2}`; // BROKEN: a string, not a number" }],
                          "notes" => "Double the amount." },
      "T1 fix" => { "edits" => [{ "op" => "replace", "path" => "src/price.ts",
                                  "search" => "  return `${n * 2}`; // BROKEN: a string, not a number", "replace" => "  return n * 2;" }],
                    "notes" => "Return a number." },
      "T2 implement" => { "edits" => [{ "op" => "create", "path" => "src/total.ts", "content" => TOTAL }],
                          "notes" => "total() on top of price() and the tax rate." },
      "review" => { "summary" => "A small change.", "findings" => [], "suspicious" => [] }
    }.freeze

    # Steps by the opening of their system prompt.
    ROLES = [["You plan", "plan"], ["You fix", "fix"], ["You make one small", "implement"], ["You are a careful code reviewer", "review"],
             ["You are a second, independent code reviewer", "review"], ["You summarize", "summary"]].freeze

    # Writes the project and its first commit, and the demo's config next to it.
    # @param dir [String] the demo's home (its config, runs/ and the project live here)
    # @param base_url [String] the scripted model server
    # @param env [Hash{String=>String}]
    # @return [Array(String, Config)] the project folder and the demo config
    # @raise [GitError]
    def self.prepare(dir, base_url, env)
      site = File.join(dir, "site-#{State::RunStore.new_run_id.delete_prefix('r')}")
      FILES.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(site, rel)))
        File.binwrite(File.join(site, rel), text)
      end
      git = Repo::Git.new(env: git_env(env), cache_dir: File.join(dir, ".cache"))
      git.run(%w[init -q -b main], chdir: site)
      git.run(%w[add -A], chdir: site)
      git.run(["commit", "--no-verify", "-m", "Demo project"], chdir: site)
      raw = config_hash(base_url)
      State.write_json(File.join(dir, "config.json"), raw)
      [site, Config.parse(raw, env: {})]
    end

    # The demo's commits carry their own author, so the demo works before git knows who the user is.
    IDENTITY = { "GIT_AUTHOR_NAME" => "vb-harness demo", "GIT_AUTHOR_EMAIL" => "demo@example.invalid",
                 "GIT_COMMITTER_NAME" => "vb-harness demo", "GIT_COMMITTER_EMAIL" => "demo@example.invalid" }.freeze

    # @param env [Hash{String=>String}]
    # @return [Hash{String=>String}]
    def self.git_env(env) = env.to_h.merge(IDENTITY)

    # @return [Hash]
    def self.config_hash(base_url)
      { "profiles" => { "default" => { "baseUrl" => base_url, "model" => MODEL, "contextTokens" => 16_384,
                                       "maxOutputTokens" => 2000, "timeoutSec" => 60 } },
        "stack" => "demo", "review" => "full", "gateEnvAllow" => IDENTITY.keys,
        "stacks" => { "demo" => { "detect" => [MARKER],
                                  "gates" => { "check" => { "argv" => [RbConfig.ruby, "tools/check.rb"], "parser" => "astro_check" } },
                                  "alwaysGates" => ["check"], "protectedPaths" => ["tools/**", MARKER] } } }
    end

    # Mark a finished demo run as one, so its report says a scripted model answered.
    # @param dir [String] the demo's home
    # @param run_id [String]
    # @return [void]
    def self.mark(dir, run_id)
      store = State::RunStore.new(runs_dir: File.join(dir, "runs"), run_id: run_id)
      store.update_run({ "demo" => true })
      Report::Render.write(store)
    end

    # A scripted OpenAI-compatible server on 127.0.0.1 with an OS-picked port. Not a model: it answers each step
    # from REPLIES, and anything else (the capability probe) with plain text.
    class Server
      # @return [void]
      def initialize
        @server = TCPServer.new("127.0.0.1", 0)
        @counts = Hash.new(0)
        @mutex = Mutex.new
        @thread = Thread.new { serve }
      end

      # @return [String] e.g. http://127.0.0.1:54321/v1
      def base_url = "http://127.0.0.1:#{@server.addr[1]}/v1"

      # @return [void]
      def stop
        @thread.kill
        @server.close
      rescue IOError
        nil
      end

      # The reply for one chat request body.
      # @param body [Hash]
      # @return [String] the message content
      def reply(body)
        messages = Array(body && body["messages"])
        system = messages.first.is_a?(Hash) ? messages.first["content"].to_s : ""
        user = messages.last.is_a?(Hash) ? messages.last["content"].to_s : ""
        step = ROLES.find { |opening, _| system.start_with?(opening) }&.last
        return "A source file of the demo project." if step == "summary"
        return "OK" unless step

        key = %w[implement fix].include?(step) ? "#{user[/^(T\d+(?:R\d+)?): /, 1]} #{step}" : step
        answer = REPLIES[key] || REPLIES[key.sub(/ fix\z/, ' implement')] || REPLIES["review"]
        @mutex.synchronize { @counts[key] += 1 }
        JSON.generate(answer)
      end

      private

      def serve
        loop do
          client = @server.accept
          handle(client)
        rescue IOError, SystemCallError
          break if @server.closed?
        ensure
          client&.close
        end
      end

      def handle(client)
        method, path = client.gets.to_s.split
        length = 0
        while (line = client.gets) && line != "\r\n"
          k, v = line.split(":", 2)
          length = v.to_i if k.to_s.strip.casecmp?("content-length")
        end
        raw = length.positive? ? client.read([length, 4 * 1024 * 1024].min).to_s : ""
        status, payload = route(method, path.to_s, raw)
        text = JSON.generate(payload)
        client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\n" \
                     "Connection: close\r\n\r\n#{text}")
      end

      def route(method, path, raw)
        return [200, { "object" => "list", "data" => [{ "id" => MODEL }] }] if method == "GET" && path.end_with?("/models")
        return [404, { "error" => { "message" => "not found" } }] unless method == "POST" && path.end_with?("/chat/completions")

        content = reply(raw.empty? ? {} : JSON.parse(raw))
        [200, { "model" => MODEL, "choices" => [{ "message" => { "role" => "assistant", "content" => content }, "finish_reason" => "stop" }],
                "usage" => { "prompt_tokens" => raw.bytesize / 4, "completion_tokens" => content.bytesize / 4 } }]
      rescue JSON::ParserError
        [400, { "error" => { "message" => "not JSON" } }]
      end
    end
  end
end
