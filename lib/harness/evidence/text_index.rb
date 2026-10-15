# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "set"

module Harness
  module Evidence
    # A small BM25 index that proposes candidate passages. Keyword overlap is never proof: the review gate checks
    # that a cited quote is verbatim in a retrieved record. Ported from REVIEWER src/evidence/text-index.js.
    class TextIndex
      STOP = %w[a an the and or of to in on for with is are be by as at it this that from into your you can use using
                when how what which not no do does if then than its].to_set.freeze
      TOKEN = %r{[a-z0-9_$@][a-z0-9_$@:./-]*[a-z0-9_$]|[a-z0-9]}
      K1 = 1.2
      B = 0.75

      # score: BM25; matched: the share of query terms the passage contains.
      Hit = Data.define(:doc, :score, :matched)

      # Identifiers stay whole (is:inline, Astro.props) and their parts are indexed too.
      # @param text [String]
      # @return [Array<String>]
      def self.tokenize(text)
        text.to_s.downcase.scan(TOKEN).each_with_object([]) do |raw, out|
          out << raw unless STOP.include?(raw)
          next unless raw.match?(%r{[:./-]})

          raw.split(%r{[:./-]+}).each { |part| out << part if part.size > 1 && !STOP.include?(part) }
        end
      end

      attr_reader :docs

      # @param docs [Array<Hash>] each with a "text" key
      def initialize(docs)
        @docs = docs
        @df = Hash.new(0)
        @tfs = docs.map do |d|
          tf = self.class.tokenize(d["text"]).tally
          tf.each_key { |t| @df[t] += 1 }
          tf
        end
        @lens = @tfs.map { |tf| tf.values.sum }
        @avg = @lens.sum.to_f / [@lens.size, 1].max
      end

      # @param query [String]
      # @param k [Integer]
      # @return [Array<Hit>] best first, score > 0 only
      def search(query, k = 5)
        terms = self.class.tokenize(query).uniq
        return [] if terms.empty?

        n = @docs.size
        hits = @tfs.each_with_index.filter_map do |tf, i|
          score = terms.sum do |t|
            f = tf[t]
            next 0.0 unless f

            idf = Math.log(1 + ((n - @df[t] + 0.5) / (@df[t] + 0.5)))
            idf * (f * (K1 + 1)) / (f + (K1 * (1 - B + (B * @lens[i] / @avg))))
          end
          Hit.new(doc: @docs[i], score: score, matched: terms.count { |t| tf.key?(t) }.fdiv(terms.size)) if score.positive?
        end
        hits.sort_by { |h| -h.score }.first(k)
      end
    end
  end
end
