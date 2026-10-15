# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "local_docs"

module Harness
  module Evidence
    # One retrieved passage, with provenance. id is its ledger id (E1, E2, ...).
    Record = Data.define(:id, :source_type, :ref, :url, :section, :excerpt, :docs_version, :major, :version_matched,
                         :label, :query)
    # The answer to one lookup: what was found and notes on what was not.
    Lookup = Data.define(:query, :evidence, :notes)

    # One lookup entry point with a fixed source hierarchy and an evidence ledger. Ported from REVIEWER
    # src/evidence/retrieve.js, local checkout only (online docs and the dataset are not ported, see
    # docs/decisions.md):
    # 1. version-matched official docs, when the checkout documents the code's major version;
    # 2. with `latest`, the checkout as a comparison when it documents another major;
    # 3. otherwise other-version docs, labelled versionMatched false.
    # Nothing is invented and no other version is silently substituted.
    class Retriever
      MIN_MATCHED = 0.5
      EXCERPT = 1400

      attr_reader :ledger

      # @param framework [Framework]
      # @param local_docs [LocalDocs, nil]
      # @param site_url [String, nil] base of the published docs, for links in the report
      def initialize(framework:, local_docs:, site_url: nil)
        @framework = framework
        @docs = local_docs
        @site_url = site_url&.chomp("/")
        @ledger = []
      end

      # @param query [String] a short query from a model: an API name or topic, never a URL
      # @param latest [Boolean]
      # @return [Lookup]
      def lookup(query:, latest: false)
        q = self.class.clean(query)
        return Lookup.new(query: query.to_s[0, 200], evidence: [], notes: ["rejected query: too short"]) unless q

        notes = []
        out = []
        hits = @docs ? @docs.search(q, 6).select { |h| h.matched >= MIN_MATCHED } : []
        notes << "local docs checkout unavailable" unless @docs
        repo_major = @framework&.known ? @framework.major : nil
        local_major = @docs&.major
        if repo_major.nil?
          notes << "#{@framework&.name || 'framework'} version unknown: no passage can be version-matched"
        elsif repo_major == local_major
          hits.first(3).each { |h| out << add(h, q, true, "version-matched") }
        else
          notes << "version-matched docs for #{@framework.name} #{repo_major} unavailable"
        end
        if latest && repo_major && local_major && repo_major != local_major
          hits.first(2).each { |h| out << add(h, q, false, "latest (comparison only)") }
        elsif out.none?(&:version_matched) && !hits.empty?
          hits.first(2).each { |h| out << add(h, q, false, "other version (docs are for #{@framework&.name} #{local_major})") }
          notes << "only #{local_major} docs matched; they are not evidence for #{repo_major} behaviour" if repo_major
        end
        notes << "no relevant evidence found" if out.empty?
        Lookup.new(query: q, evidence: out, notes: notes)
      end

      # @param id [String]
      # @return [Record, nil]
      def get(id)
        @ledger.find { |r| r.id == id }
      end

      # @param query [Object]
      # @return [String, nil] nil when too short
      def self.clean(query)
        s = query.to_s.gsub(%r{https?://\S+}, " ").gsub(/[\u0000-\u001f\u007f]/, " ").squeeze(" ").strip
        s.size < 3 ? nil : s[0, 200]
      end

      # How a lookup is shown to a model: data, to be fenced by the caller.
      # @param result [Lookup]
      # @return [String]
      def self.format(result)
        lines = ["Results for \"#{result.query}\":"]
        result.evidence.each do |e|
          lines << "[#{e.id}] #{e.label} | #{e.source_type} | docs #{e.docs_version} | #{e.url || e.ref}"
          lines << e.excerpt << ""
        end
        lines << "(no relevant evidence found)" if result.evidence.empty?
        lines << "Notes: #{result.notes.join('; ')}" unless result.notes.empty?
        lines.join("\n")
      end

      private

      def add(hit, query, matched, label)
        d = hit.doc
        url = @site_url && "#{@site_url}/#{d['slug']}/#{d['anchor'].empty? ? '' : "##{d['anchor']}"}"
        rec = Record.new(id: "E#{@ledger.size + 1}", source_type: "official-docs",
                         ref: "#{LocalDocs::CONTENT}/#{d['path']}#L#{d['lineStart']}-L#{d['lineEnd']}", url: url,
                         section: d["heading"], excerpt: d["text"][0, EXCERPT],
                         docs_version: "#{@docs.documents_up_to} (checkout #{@docs.commit.to_s[0, 9]})", major: @docs.major,
                         version_matched: matched, label: label, query: query)
        @ledger << rec
        rec
      end
    end
  end
end
