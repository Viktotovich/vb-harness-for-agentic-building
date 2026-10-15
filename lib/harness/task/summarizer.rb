# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../model/client"
require_relative "../model/tokens"
require_relative "../prompts"
require_relative "../untrusted"
require_relative "gather"

module Harness
  module Task
    # One-sentence file summaries from the summarizer role, for the context map (DESIGN.md 5.2). A summary is
    # a nicety: any model problem gives nil and the bundle goes without it.
    class Summarizer
      # @param client [Model::Client]
      # @param config [Config]
      def initialize(client:, config:)
        @client = client
        @config = config
      end

      # @param path [String]
      # @param content [String]
      # @return [String, nil] the sentence, or nil when the model failed or the reply reads like an instruction
      def call(path, content)
        system = Prompts.render("summarize_system")
        room = Gather.budget(client: @client, config: @config, role: :summarizer, system: system, schema: nil)
        max = [(room - Model::Tokens.estimate(path) - 50) * Model::Tokens::BYTES_PER_TOKEN, 0].max.to_i
        body = content.bytesize > max ? "#{content.byteslice(0, max).scrub}\n[the rest of the file is cut]" : content
        user = Prompts.render("summarize_user", path: path, content: Untrusted.fence(body))
        text = @client.complete(:summarizer, Model::Messages.new(system: system, user: user), label: "summary").text.to_s
        Untrusted.instruction_like?(text) ? nil : text
      rescue ModelOutputError, ModelUnavailableError, ContextOverflowError
        nil
      end
    end
  end
end
