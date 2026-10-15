# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "securerandom"

module Harness
  # Untrusted text handling (I9, DESIGN.md 9.4), ported from REVIEWER src/review/prompt.js.
  # Repo content, docs, gate output and earlier model output reach a model only inside a nonce fence,
  # and instruction-like text is detected deterministically, whatever the model makes of it.
  module Untrusted
    TAG = "untrusted-data"

    # [label, pattern] pairs; the first match per source is reported.
    INJECTION_PATTERNS = [
      ["approval request", /\b(?:approve|approving|lgtm)\b[^.\n]{0,40}\b(?:pr|pull request|merge request|change|changes|this)\b/i],
      ["approval request", /\b(?:merge|approve)\s+(?:it|this|immediately|now|without)\b/i],
      ["override instructions", /\b(?:ignore|disregard|forget|override)\b[^.\n]{0,30}\b(?:instructions?|prompts?|rules|guidelines|system)\b/i],
      ["role/identity override", /\byou are (?:now|actually|no longer)\b/i],
      ["prompt reference", /\b(?:system|developer)\s+(?:prompt|message|instructions?)\b/i],
      ["chat-template tokens", %r{<\|(?:im_start|im_end|system|user|assistant|endoftext)\|>|\[/?INST\]|</?(?:system|assistant)>}i],
      ["suppress findings", /\b(?:do not|don't|never)\s+(?:report|flag|mention|comment on|review)\b/i],
      ["force verdict", /\b(?:set|mark|rate|report)\b[^.\n]{0,20}\brisk\b[^.\n]{0,15}\b(?:low|none|safe)\b/i],
      ["command execution", /\b(?:run|execute)\s+(?:the following|this|these)\s+(?:command|commands|script)\b/i],
      ["gh command", /\bgh\s+(?:pr\s+(?:review|merge|close)|api|repo\s+(?:delete|edit)|issue\s+create)\b/i],
      ["note to AI", /\b(?:note|message|instruction)s?\s+(?:to|for)\s+(?:the\s+)?(?:ai|llm|bot|reviewer|assistant|model)\b/i]
    ].freeze
    MAX_HITS = 20

    Hit = Data.define(:source, :label, :excerpt)

    # Wrap untrusted text in the nonce fence. Text that imitates the fence tag is neutralised, so it cannot
    # close the fence early.
    # @param text [String, nil]
    # @param nonce [String]
    # @return [String]
    def self.fence(text, nonce: SecureRandom.hex(6))
      ["<#{TAG} id=\"#{nonce}\">", neutralise(text), "</#{TAG} id=\"#{nonce}\">"].join("\n")
    end

    # @param text [String, nil]
    # @return [String]
    def self.neutralise(text)
      text.to_s.gsub(/#{TAG}/i, "untrusted_data_removed")
    end

    # Scan untrusted sources for instruction-like text.
    # @param sources [Array<Array(String, String)>] [source label, text] pairs, e.g. ["src/a.ts", content]
    # @return [Array<Hit>] at most one hit per source, at most MAX_HITS in all
    def self.detect_injection(sources)
      sources.filter_map do |source, text|
        s = text.to_s
        INJECTION_PATTERNS.lazy.filter_map do |label, re|
          m = s.match(re) or next
          start = [0, m.begin(0) - 20].max
          Hit.new(source: source, label: label, excerpt: s[start, m.end(0) - start + 20].gsub(/\s+/, " ").strip)
        end.first
      end.first(MAX_HITS)
    end

    # @param text [String]
    # @return [Boolean]
    def self.instruction_like?(text)
      INJECTION_PATTERNS.any? { |_, re| text.to_s.match?(re) }
    end

    # A model's own "suspicious" quotes are not trusted either: keep a quote only if it appears verbatim in
    # the untrusted text and looks like an instruction.
    # @param quotes [Array<String>]
    # @param haystack [String] all untrusted text the model was shown
    # @return [Array<String>]
    def self.filter_model_suspicious(quotes, haystack)
      hay = squash(haystack)
      seen = {}
      quotes.select do |q|
        s = squash(q).gsub(/\A["'“”]+|["'“”.]+\z/, "")
        keep = s.length >= 8 && !seen.key?(s) && hay.include?(s) && instruction_like?(q)
        seen[s] = true if keep
        keep
      end
    end

    # @return [String]
    def self.squash(text)
      text.to_s.downcase.gsub(/\s+/, " ").strip
    end
    private_class_method :squash
  end
end
