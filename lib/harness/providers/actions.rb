# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../exec"

module Harness
  module Providers
    # The provider CLI actions onboarding may run after a click (DESIGN.md 11.2): a fixed list of subcommands, argv
    # arrays through Harness::Exec (I3), model names checked before they reach argv. There is no other way to run a
    # command from the app.
    module Actions
      MODEL = %r{\A[\w.:/@-]{1,200}\z}
      # kind => action => [argv after the tool, takes a model name?, timeout in seconds]
      LIST = {
        "lmstudio" => { "server_start" => [%w[server start], false, 60], "ls" => [%w[ls --json], false, 30],
                        "load" => [%w[load], true, 600], "ps" => [%w[ps], false, 30] },
        "ollama" => { "list" => [%w[list], false, 30], "pull" => [%w[pull], true, 3600], "ps" => [%w[ps], false, 30] }
      }.freeze

      # What an action did. output is the tool's stdout and stderr, trimmed.
      Outcome = Data.define(:ok, :output)

      # @param kind [String] "lmstudio" or "ollama"
      # @param action [String] a key of LIST[kind]
      # @param model [String, nil] for load and pull
      # @return [Array<String>] the argv after the tool
      # @raise [ParseError] for anything not on the list
      def self.argv(kind, action, model = nil)
        spec = LIST.dig(kind, action) or raise ParseError, "no provider action #{kind}/#{action}"
        args, takes_model, = spec
        return args unless takes_model
        raise ParseError, "model name #{model.to_s[0, 60].inspect} is not allowed" unless model.is_a?(String) && model.match?(MODEL)

        args + [model]
      end

      # @param cli [Array<String>] the tool's argv prefix, from Detect
      # @param kind [String]
      # @param action [String]
      # @param model [String, nil]
      # @param env [Hash{String=>String}]
      # @param chdir [String]
      # @return [Outcome]
      # @raise [ParseError]
      def self.run(cli:, kind:, action:, env:, chdir:, model: nil)
        args = argv(kind, action, model)
        r = Exec.run(cli + args, chdir: chdir, env: env, timeout: LIST.dig(kind, action)[2], max_output: 65_536)
        text = "#{r.stdout}\n#{r.stderr}".strip
        Outcome.new(ok: r.success?, output: text.size > 4000 ? text[-4000..] : text)
      rescue CommandNotFoundError, UnsafeArgumentError => e
        Outcome.new(ok: false, output: e.message)
      end

      # Models LM Studio has downloaded, from `lms ls --json`.
      # @param output [String]
      # @return [Array<String>] model keys
      def self.lms_models(output)
        list = JSON.parse(output[/\[.*\]/m].to_s)
        Array(list).filter_map { |m| (m["modelKey"] || m["path"]) if m.is_a?(Hash) }.select { |k| k.is_a?(String) && k.match?(MODEL) }
      rescue JSON::ParserError
        []
      end
    end
  end
end
