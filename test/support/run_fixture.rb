# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "fake_llm_server"

module TestSupport
  # A tiny Astro-like repository with a fake type checker (a Ruby script, so tests need no Node), and helpers
  # to run the pipeline on it against a scripted fake model.
  module RunFixture
    TYPECHECK = <<~RUBY
      bad = Dir.glob("src/**/*.ts").sort.flat_map do |f|
        File.readlines(f).each_with_index.filter_map do |line, i|
          next unless line.include?("BROKEN")

          tag = line[/BROKEN (\\d+)/, 1]
          msg = tag ? "Value \#{tag} is not a number." : "Type 'string' is not assignable to type 'number'."
          "\#{f}:\#{i + 1}:3 - error ts(2322): \#{msg}"
        end
      end
      puts bad
      exit(bad.empty? ? 0 : 1)
    RUBY

    FILES = {
      "package.json" => %({"name": "astro-mini", "private": true}\n),
      "astro.config.mjs" => "export default {};\n",
      "src/lib/price.ts" => "export function price(n: number): number {\n  return n;\n}\n",
      "src/lib/tax.ts" => "export const rate = 0.2;\n",
      "tools/typecheck.rb" => TYPECHECK
    }.freeze

    # @return [Harness::Config]
    def self.config(base_url)
      ruby = RbConfig.ruby
      Harness::Config.parse({
                              "profiles" => { "default" => { "baseUrl" => base_url, "maxOutputTokens" => 1000 } },
                              "gateEnvAllow" => %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM],
                              "stacks" => { "astro" => {
                                "detect" => ["astro.config.mjs"],
                                "gates" => {
                                  "typecheck" => { "argv" => [ruby, "tools/typecheck.rb"], "parser" => "astro_check", "costRank" => 3 },
                                  "build" => { "argv" => [ruby, "-e", "exit 0"], "when" => "integration", "costRank" => 8 }
                                },
                                "alwaysGates" => ["typecheck"],
                                "protectedPaths" => [".env*", "tools/**"]
                              } }
                            })
    end

    # A plan task in its JSON form.
    # @return [Hash]
    def self.task(id, title, modify:, depends: [])
      { "id" => id, "title" => title, "intent" => "#{title}.", "files" => { "modify" => modify },
        "dependsOn" => depends, "acceptance" => [{ "kind" => "gate", "gate" => "typecheck" }] }
    end

    # @return [Array(Integer, Hash)] a fake chat reply holding one replace edit
    def self.replace(path, search, with)
      FakeLlmServer.ok(JSON.generate({ "edits" => [{ "op" => "replace", "path" => path, "search" => search, "replace" => with }],
                                       "notes" => "edit" }))
    end

    Result = Data.define(:outcome, :repo, :env, :store, :server)

    # Run a plan end to end. replies: { "T1 implement" => reply, "T1 fix" => reply, ... }, a reply may be an
    # Array consumed in order (the last repeats).
    # @return [Result]
    def self.run(tmp, plan, replies, files: FILES)
      repo, env = TestSupport.repo(tmp, files)
      counts = Hash.new(0)
      server = FakeLlmServer.new do |body, _n|
        system = body["messages"].first["content"]
        user = body["messages"].last["content"]
        id = user[/^(T\d+): /, 1]
        step = if user.include?("could not be applied") then "retry"
               elsif system.start_with?("You fix") then "fix"
               else "implement"
               end
        key = "#{id} #{step}"
        value = replies.fetch(key) { raise "fake model: no reply for #{key}" }
        list = value.first.is_a?(Integer) ? [value] : value
        reply = list[[counts[key], list.size - 1].min]
        counts[key] += 1
        reply
      end
      config = config(server.base_url)
      store = Harness::State::RunStore.new(runs_dir: File.join(tmp, "runs"), run_id: "r1")
      client = Harness::Model::Client.new(
        config: config, probe: ->(_) { Harness::Model::Probe::Result.new(**CAPS) }, http: Harness::Model::Http.new,
        records: Harness::State::Records.new(store.records_dir), env: {}, sleeper: ->(_) {}
      )
      setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
      outcome = Harness::Run.new(config: config, client: client, setup: setup).execute(Harness::Plan::PlanParser.parse(plan))
      Result.new(outcome: outcome, repo: repo, env: env, store: store, server: server)
    end
  end
end
