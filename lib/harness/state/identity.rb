# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../prompts"
require_relative "../sha256"
require_relative "../version"

module Harness
  module State
    # What produced a run: the harness version, its prompt files and the effective config, recorded in run.json at
    # intake and compared when the run is answered or resumed. A field run crashed after its prompts were edited
    # mid-run, and resume could not tell anything had changed.
    #
    # A new harness version or new prompts would run the rest of the tasks on different code or instructions than
    # the first ones, so they stop the run unless accepted. A changed config only warns: raising timeoutSec and
    # resuming is the documented fix for timeouts.
    module Identity
      # Fields whose change stops a resume, with the words used for them.
      STRICT = { "harnessVersion" => "the harness version", "prompts" => "the prompt files" }.freeze

      # @param config [Config]
      # @return [Hash{String=>String}] harnessVersion, prompts and config (short digests)
      def self.current(config)
        { "harnessVersion" => VERSION, "prompts" => prompts_digest, "config" => config_digest(config) }
      end

      # @param recorded [Hash, nil] run.json's identity; nil for runs started before identities were recorded
      # @param now [Hash] #current
      # @param accept [Boolean] continue even when a strict field changed
      # @return [Array<String>] warnings for the changes that do not stop the run
      # @raise [ConfigError] naming each strict field that changed, unless accept
      def self.check!(recorded, now, accept: false)
        return [] unless recorded.is_a?(Hash)

        strict = STRICT.filter_map do |key, words|
          "#{words} (#{recorded[key]} then, #{now[key]} now)" if recorded[key] != now[key]
        end
        unless strict.empty? || accept
          raise ConfigError, "#{strict.join(' and ')} changed since this run started, so the rest of it would not run " \
                             "on what its first part ran on. Start a new run, or pass --accept-changes to continue anyway"
        end

        warnings = strict.map { |s| "#{s} changed; continuing (--accept-changes)" }
        warnings << "the config changed since the run started; the rest of the run uses the new one" if recorded["config"] != now["config"]
        warnings
      end

      # @return [String] 16 hex characters over every prompt file's name and bytes
      def self.prompts_digest
        files = Dir.glob(File.join(Prompts::DIR, "*")).sort.select { |f| File.file?(f) }
        Sha256.hex(files.map { |f| "#{File.basename(f)}\0#{File.binread(f)}\0" }.join)[0, 16]
      end

      # The command-line overrides (--review, --require-green-baseline) are left out: giving one on resume is a
      # choice for that step, not a change of config.
      # @param config [Config]
      # @return [String] 16 hex characters
      def self.config_digest(config)
        Sha256.hex(config.with(review: "full", require_green_baseline: false).inspect)[0, 16]
      end
    end
  end
end
