# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "securerandom"
require_relative "../errors"
require_relative "../model/http"
require_relative "../model/probe"
require_relative "../model/stream"
require_relative "../model/tokens"
require_relative "../prompts"
require_relative "../untrusted"

module Harness
  module UI
    # Chat mode (DESIGN.md 11.3): the conversation goes to the chosen model and streams back. It is fitted to the
    # context with the budget rules of section 7: the newest messages are kept, and the oldest become a summary.
    class Conversation
      SUMMARY_TOKENS = 600
      LIST_TIMEOUT = 3
      RETRY_NOTICE = "The model ran out of room while thinking; asking again with thinking off."

      # @param config [Config]
      # @param chats [Chats]
      # @param probe [Model::Probe]
      # @param stream [Model::Stream]
      # @param http [Model::Http]
      # @param env [Hash{String=>String}]
      def initialize(config:, chats:, probe:, stream:, http:, env:)
        @config = config
        @chats = chats
        @probe = probe
        @stream = stream
        @http = http
        @env = env
        @jobs = {}
        @mutex = Mutex.new
      end

      # Every model of every configured profile, as "profile · model id".
      # @return [Array<Hash>] profile, model, label, and error when the server could not be asked
      def models
        @config.profiles.values.flat_map do |p|
          res = @http.get("#{p.base_url}/models", headers: Model::Probe.headers(p, @env), timeout: LIST_TIMEOUT)
          ids = res.ok? && res.json.is_a?(Hash) ? Array(res.json["data"]).filter_map { |m| m["id"] if m.is_a?(Hash) } : []
          ids = [p.model] if ids.empty?
          ids.map { |id| { "profile" => p.name, "model" => id, "label" => "#{p.name} · #{id}" } }
        rescue ModelUnavailableError => e
          [{ "profile" => p.name, "model" => p.model, "label" => "#{p.name} · #{p.model}", "error" => e.message }]
        end
      end

      # Register a reply to stream; it starts when the browser opens the stream.
      # @param chat_id [String]
      # @return [String] the stream id
      def prepare(chat_id)
        id = SecureRandom.hex(8)
        @mutex.synchronize { @jobs[id] = { chat: chat_id, stop: false } }
        id
      end

      # @param id [String]
      # @return [Boolean] whether there was such a stream
      def stop(id)
        @mutex.synchronize do
          job = @jobs[id]
          job[:stop] = true if job
          !job.nil?
        end
      end

      # Generate the reply into the SSE stream, then save it to the chat.
      # @param id [String] from prepare
      # @param sse [SSE]
      # @return [void]
      def run(id, sse)
        job = @mutex.synchronize { @jobs[id] }
        return sse.event("error", { "error" => "no such stream" }) unless job

        chat = @chats.get(job[:chat])
        profile, model = choice(chat)
        text = +""
        thinking = +""
        messages = fit(chat, profile)
        reply = lambda do |off|
          @stream.call(profile: profile, model: model, messages: messages, max_tokens: profile.max_output_tokens,
                       thinking_off: off, stop: -> { job[:stop] || sse.closed? }) do |piece|
            (piece.kind == "text" ? text : thinking) << piece.text
            sse.event(piece.kind, { "text" => piece.text })
          end
        end
        finish = reply.call(nil)
        retried = false
        control = out_of_room?(finish, text) ? @probe.call(profile).thinking_control : "none"
        if control != "none"
          # Like the model client: a reply that spent its whole allowance thinking is asked again once, thinking off.
          retried = true
          sse.event("notice", { "text" => RETRY_NOTICE })
          finish = reply.call(control)
        end
        if out_of_room?(finish, text)
          return sse.event("error", { "error" => "The model used its whole output allowance (#{profile.max_output_tokens} tokens) " \
                                                 "on thinking and gave no answer#{retried ? ', even with thinking off' : ''}. Raise " \
                                                 "maxOutputTokens for this profile, or ask a narrower question." })
        end

        @chats.append(chat["id"], { "role" => "assistant", "content" => text, "thinking" => thinking.empty? ? nil : thinking,
                                    "model" => "#{profile.name} · #{model}", "finish" => finish, "retried" => retried || nil }.compact)
        sse.event("done", { "finish" => finish })
      rescue ModelUnavailableError, ConfigError => e
        sse.event("error", { "error" => e.message })
      ensure
        @mutex.synchronize { @jobs.delete(id) }
      end

      private

      # @return [Boolean] the reply ended at the output limit with no answer text
      def out_of_room?(finish, text)
        finish == "length" && text.strip.empty?
      end

      # @return [Array(Model::Profile, String)]
      def choice(chat)
        want = chat["model"].is_a?(Hash) ? chat["model"] : {}
        profile = @config.profiles[want["profile"]] || @config.profile_for(:implementer)
        [profile, want["model"].is_a?(String) && !want["model"].empty? ? want["model"] : profile.model]
      end

      # The newest messages that fit, after a summary of the older ones.
      # @return [Array<Hash>]
      def fit(chat, profile)
        system = Prompts.render("chat_system")
        context = @probe.call(profile).context_tokens
        budget = context - profile.max_output_tokens - Model::Tokens.estimate(system) - SUMMARY_TOKENS
        turns = chat["messages"].each_with_index.select { |m, _| %w[user assistant].include?(m["role"]) }
        kept = []
        used = 0
        turns.reverse_each do |m, i|
          cost = Model::Tokens.estimate(m["content"]) + Model::Tokens::MESSAGE_OVERHEAD
          break if used + cost > budget && !kept.empty?

          kept.unshift([m, i])
          used += cost
        end
        older = turns.take(turns.size - kept.size)
        out = [{ "role" => "system", "content" => system }]
        out << { "role" => "system", "content" => "Summary of the earlier conversation:\n#{summary(chat, older, profile)}" } unless older.empty?
        out + kept.map { |m, _| { "role" => m["role"], "content" => m["content"].to_s } }
      end

      # @return [String] cached in the chat until more messages fall out of the window
      def summary(chat, older, profile)
        upto = older.last[1]
        cached = chat["summary"]
        return cached["text"] if cached.is_a?(Hash) && cached["upTo"] == upto

        transcript = older.map { |m, _| "#{m['role']}: #{m['content']}" }.join("\n\n")
        prompt = [{ "role" => "system", "content" => Prompts.render("chat_summary") },
                  { "role" => "user", "content" => Untrusted.fence(transcript[-(SUMMARY_TOKENS * 20)..] || transcript) }]
        text = +""
        @stream.call(profile: profile, model: choice(chat)[1], messages: prompt, max_tokens: SUMMARY_TOKENS) do |piece|
          text << piece.text if piece.kind == "text"
        end
        @chats.update(chat["id"]) { |c| c["summary"] = { "upTo" => upto, "text" => text.strip } }
        text.strip
      end
    end
  end
end
