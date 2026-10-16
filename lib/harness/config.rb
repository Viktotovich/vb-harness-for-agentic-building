# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "parse"
require_relative "model/profiles"
require_relative "gates/gate"

module Harness
  # Limits with their defaults from DESIGN.md section 14.
  Limits = Data.define(:max_files_per_task, :max_fix_rounds, :max_replan_rounds, :max_diagnostics, :max_lookups,
                       :max_review_fix_tasks, :whole_file_rewrite_max_bytes, :max_gate_output_bytes)

  # Validated config.json. stacks maps a stack name to a Gates::Stack.
  # projects: folders linked in the app (name => absolute path); they live only in the local config.json.
  Config = Data.define(:profiles, :roles, :limits, :stack, :stacks, :gate_env_allow, :dry_run, :projects) do
    # @param role [Symbol] one of Model::ROLES
    # @return [Model::Profile]
    # @raise [ArgumentError] on an unknown role
    def profile_for(role)
      name = roles.fetch(role) { raise ArgumentError, "unknown role #{role.inspect}" }
      profiles.fetch(name)
    end
  end

  class Config
    LIMIT_DEFAULTS = {
      "maxFilesPerTask" => [:max_files_per_task, 3],
      "maxFixRounds" => [:max_fix_rounds, 3],
      "maxReplanRounds" => [:max_replan_rounds, 2],
      "maxDiagnostics" => [:max_diagnostics, 20],
      "maxLookups" => [:max_lookups, 6],
      "maxReviewFixTasks" => [:max_review_fix_tasks, 2],
      "wholeFileRewriteMaxBytes" => [:whole_file_rewrite_max_bytes, 4096],
      "maxGateOutputBytes" => [:max_gate_output_bytes, 204_800]
    }.freeze
    TOP_KEYS = (%w[profiles roles stack stacks gateEnvAllow dryRun projects] + LIMIT_DEFAULTS.keys).freeze
    PROJECT_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

    # Read and validate a config file.
    # @param path [String]
    # @param env [Hash{String=>String}] for HARNESS_<PROFILE>_BASE_URL / _MODEL overrides
    # @return [Config]
    # @raise [ParseError]
    def self.load(path, env: ENV)
      text = File.read(path, encoding: "UTF-8")
      parse(JSON.parse(text), env: env)
    rescue Errno::ENOENT
      raise ParseError, "config: #{File.basename(path)} not found (run `harness init`)"
    rescue JSON::ParserError => e
      raise ParseError, "config: #{File.basename(path)} is not valid JSON (#{e.message.lines.first.strip})"
    end

    # @param raw [Hash] the parsed JSON document
    # @param env [Hash{String=>String}]
    # @return [Config]
    # @raise [ParseError]
    def self.parse(raw, env: {})
      h = Parse.hash!(raw, "config")
      Parse.known_keys!(h, TOP_KEYS, "")
      profiles = parse_profiles(h["profiles"], env)
      new(
        profiles: profiles,
        roles: Model::Roles.parse(h["roles"], profiles.keys).freeze,
        limits: parse_limits(h),
        stack: Parse.str!(h.fetch("stack", "auto"), "stack"),
        stacks: Parse.hash!(h.fetch("stacks", {}), "stacks").to_h { |name, s| [name, Gates::Stack.parse(name, s)] }.freeze,
        gate_env_allow: Parse.strings!(h.fetch("gateEnvAllow", []), "gateEnvAllow").dup.freeze,
        dry_run: Parse.bool!(h.fetch("dryRun", false), "dryRun"),
        projects: parse_projects(h.fetch("projects", []))
      )
    end

    # @return [Hash{String=>String}] name => absolute path
    # @raise [ParseError]
    def self.parse_projects(raw)
      Parse.fail!("projects", "array", raw) unless raw.is_a?(Array)
      raw.each_with_index.to_h do |p, i|
        h = Parse.hash!(p, "projects[#{i}]")
        Parse.known_keys!(h, %w[name path], "projects[#{i}]")
        name = Parse.str!(h["name"], "projects[#{i}].name")
        Parse.fail!("projects[#{i}].name", "a short name of letters, digits, . _ -", name) unless name.match?(PROJECT_NAME)
        [name, Parse.str!(h["path"], "projects[#{i}].path")]
      end.freeze
    end

    # @return [Limits]
    def self.parse_limits(h)
      Limits.new(**LIMIT_DEFAULTS.to_h { |key, (field, default)| [field, Parse.int!(h.fetch(key, default), key, min: 1)] })
    end

    # @return [Hash{String=>Model::Profile}]
    def self.parse_profiles(raw, env)
      h = Parse.hash!(raw, "profiles")
      raise ParseError, "profiles: at least one profile is required" if h.empty?

      profiles = h.to_h { |name, p| [name, Model::Profile.parse(name, apply_env(name, p, env))] }
      profiles.each_value do |p|
        next if p.fallback.nil?
        raise ParseError, "profiles.#{p.name}.fallback: cannot name itself" if p.fallback == p.name

        Model::Roles.check_name!(p.fallback, "profiles.#{p.name}.fallback", profiles.keys)
      end
      profiles.freeze
    end

    # HARNESS_<NAME>_BASE_URL and HARNESS_<NAME>_MODEL override a profile, NAME upper-cased with
    # other characters as "_".
    # @return [Object] the profile hash with overrides applied
    def self.apply_env(name, raw, env)
      return raw unless raw.is_a?(Hash)

      key = name.upcase.gsub(/[^A-Z0-9]/, "_")
      out = raw.dup
      out["baseUrl"] = env["HARNESS_#{key}_BASE_URL"] if env["HARNESS_#{key}_BASE_URL"]
      out["model"] = env["HARNESS_#{key}_MODEL"] if env["HARNESS_#{key}_MODEL"]
      out
    end
    private_class_method :parse_projects, :parse_limits, :parse_profiles, :apply_env
  end
end
