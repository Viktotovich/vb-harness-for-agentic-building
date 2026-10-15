# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"

module Harness
  module Evidence
    # Which version of the stack's framework the code uses. known is false when no major version is established;
    # version-dependent claims then cannot be verified.
    Framework = Data.define(:known, :name, :package, :declared, :installed, :major, :source, :notes) do
      # The line every review prompt carries, uncertainty included.
      # @return [String]
      def line
        return "Framework: no #{name} (no #{package} dependency found)" if !known && declared.nil? && source == "package.json"
        return "Framework: #{name}, version UNKNOWN (#{notes.empty? ? 'not established' : notes.join('; ')})" unless known

        "Framework: #{name} #{installed || "#{major}.x"} (from #{source}#{declared ? ", declared #{declared}" : ''})"
      end
    end

    # Reads the framework version from the repository: the lockfile first, then package.json's range.
    # Ported from REVIEWER src/evidence/version.js.
    module Version
      LOCKFILES = %w[package-lock.json pnpm-lock.yaml yarn.lock].freeze

      # @param file [String] lockfile name
      # @param text [String, nil]
      # @param package [String] npm package name
      # @return [String, nil] the resolved x.y.z
      def self.parse_lock(file, text, package)
        return nil if text.nil? || text.empty?

        pkg = Regexp.escape(package)
        case file
        when "package-lock.json"
          j = JSON.parse(text)
          j.dig("packages", "node_modules/#{package}", "version") || j.dig("dependencies", package, "version")
        when "pnpm-lock.yaml"
          text[/^\s+#{pkg}:\s*\n\s+specifier:[^\n]*\n\s+version:\s*'?(\d+\.\d+\.\d+)/, 1] || text[%r{\n\s+/?#{pkg}@(\d+\.\d+\.\d+)}, 1]
        when "yarn.lock"
          text[/^"?#{pkg}@[^\n]*:\n\s+version "?(\d+\.\d+\.\d+)/, 1]
        end
      rescue JSON::ParserError
        nil
      end

      # @param range [String, nil] a semver range
      # @return [Integer, nil] the major it pins, nil when it allows more than one
      def self.major_from_range(range)
        r = range.to_s.strip
        if (m = r.match(/\A[~^=v]?\s*(\d+)(?:\.\d+){0,2}\z/))
          return m[1].to_i
        end

        m = r.match(/\A>=\s*(\d+)\.\d+(?:\.\d+)?\s*<\s*(\d+)/)
        m && m[2].to_i == m[1].to_i + 1 ? m[1].to_i : nil
      end

      # @param root [String] worktree root
      # @param name [String] display name, e.g. from the stack's framework.name
      # @param package [String] the npm package holding the version
      # @return [Framework]
      def self.detect(root, name:, package:)
        notes = []
        pkg = begin
          JSON.parse(File.read(File.join(root, "package.json")))
        rescue Errno::ENOENT
          notes << "no package.json"
          nil
        rescue JSON::ParserError
          notes << "package.json unreadable"
          nil
        end
        declared = pkg.is_a?(Hash) ? pkg.dig("dependencies", package) || pkg.dig("devDependencies", package) : nil
        base = { name: name, package: package, declared: declared, installed: nil, major: nil }
        if pkg.is_a?(Hash) && declared.nil?
          return Framework.new(known: false, source: "package.json", notes: ["#{package} is not a dependency"], **base)
        end

        LOCKFILES.each do |file|
          path = File.join(root, file)
          v = File.file?(path) ? parse_lock(file, File.read(path), package) : nil
          next unless v

          return Framework.new(**base, known: true, installed: v, major: v.split(".").first.to_i, source: file, notes: notes)
        end
        major = major_from_range(declared)
        if major
          return Framework.new(**base, known: true, major: major, source: "package.json (range)",
                                       notes: notes + ["no lockfile: exact version unknown"])
        end

        Framework.new(**base, known: false, source: "package.json",
                              notes: notes + [declared ? "range \"#{declared}\" does not pin a major version" : "version not found"])
      end
    end
  end
end
