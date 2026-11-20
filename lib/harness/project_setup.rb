# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC


require_relative "errors"
require_relative "exec"

module Harness
  # One-click fixes for a project that is not ready to build in: its dependencies are not installed, a folder the
  # stack needs (a generated client) is missing, or a check's tool says it needs a package. Each fix is a fixed argv
  # built here or taken from the stack's config ("setup"), never from a model or a request; the app shows the exact
  # command and runs it only after the user confirms (I3, I10). Installs use --ignore-scripts.
  module ProjectSetup
    # id: stable name the page sends back; label: what it does, for people; steps: the commands, run in order;
    # commit: after the steps, commit the dependency files they changed (package.json, lockfiles) and nothing else,
    # so the project is clean again and a build can start at once.
    Fix = Data.define(:id, :label, :steps, :commit) do
      # @param id [String]
      # @param label [String]
      # @param steps [Array<Array<String>>]
      # @param commit [Boolean]
      def initialize(id:, label:, steps:, commit: false) = super

      # @return [String] the commands as a person would type them, for display only (never run as a string)
      def command
        shown = steps.map { |argv| argv.map { |a| Fix.shown(a) }.join(" ") }
        shown << "git commit (the changed package files only)" if commit
        shown.join(" && ")
      end

      # @param arg [String]
      # @return [String] the argument, in double quotes when it has a space or another special character
      def self.shown(arg)
        arg.match?(%r{\A[\w@%+=:,./{}-]+\z}) ? arg : "\"#{arg.gsub('"', '\\"')}\""
      end

      # @return [Hash]
      def to_json_hash = { "id" => id, "label" => label, "command" => command }
    end

    # An npm package name, optionally scoped: what a check's output may ask for.
    PACKAGE = %r{\A(?:@[a-z0-9][\w.-]{0,100}/)?[a-z0-9][\w.-]{0,100}\z}
    LOCKFILES = { "pnpm-lock.yaml" => "pnpm", "yarn.lock" => "yarn", "bun.lock" => "bun", "bun.lockb" => "bun" }.freeze
    # With a lockfile: install exactly what it lists and leave it as it is. Without one: install without writing one,
    # so a clean project stays clean and can be built in at once.
    INSTALL_LOCKED = { "npm" => %w[npm ci --ignore-scripts], "pnpm" => %w[pnpm install --frozen-lockfile --ignore-scripts],
                       "yarn" => %w[yarn install --frozen-lockfile --ignore-scripts],
                       "bun" => %w[bun install --frozen-lockfile --ignore-scripts] }.freeze
    INSTALL_FREE = { "npm" => %w[npm install --no-package-lock --ignore-scripts], "pnpm" => %w[pnpm install --no-lockfile --ignore-scripts],
                     "yarn" => %w[yarn install --no-lockfile --ignore-scripts], "bun" => %w[bun install --no-save --ignore-scripts] }.freeze
    # Files a dependency change touches: when they are the only uncommitted changes, committing them is a fix too.
    DEPENDENCY_FILES = %w[package.json package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb npm-shrinkwrap.json].freeze
    ADD_DEV = { "npm" => %w[npm install --save-dev --ignore-scripts], "pnpm" => %w[pnpm add -D --ignore-scripts],
                "yarn" => %w[yarn add -D --ignore-scripts], "bun" => %w[bun add -d --ignore-scripts] }.freeze
    # The prefix Gates::Runner gives a check skipped because its tool asked for packages.
    NEEDS = "packages not installed: "
    TIMEOUT = 900

    # @param stack [Gates::Stack]
    # @param top [String] the project's folder
    # @return [String] npm, pnpm, yarn or bun
    def self.package_manager(stack, top)
      return stack.package_manager unless stack.package_manager == "auto"

      LOCKFILES.find { |f, _| File.file?(File.join(top, f)) }&.last || "npm"
    end

    # @param stack [Gates::Stack]
    # @param top [String]
    # @return [Array<String>] dependencyDirs folders that are not there
    def self.missing_dirs(stack, top)
      stack.dependency_dirs.reject { |d| File.directory?(File.join(top, d)) }
    end

    # @param reasons [Array<String, nil>] skip reasons of checks
    # @return [Array<String>] the valid package names they ask for
    def self.packages_from(reasons)
      reasons.compact.select { |r| r.start_with?(NEEDS) }.flat_map { |r| r.delete_prefix(NEEDS).split(/,\s*/) }
             .map(&:strip).select { |p| p.match?(PACKAGE) }.uniq
    end

    # @param stack [Gates::Stack]
    # @param top [String]
    # @param packages [Array<String>] packages a check asked for
    # @return [Array<Fix>] in the order to run them
    def self.fixes(stack, top, packages: [])
      missing = missing_dirs(stack, top)
      manager = package_manager(stack, top)
      out = []
      if missing.include?("node_modules") && File.file?(File.join(top, "package.json"))
        locked = (LOCKFILES.keys + %w[package-lock.json npm-shrinkwrap.json]).any? { |f| File.file?(File.join(top, f)) }
        out << Fix.new(id: "install", label: "Install the project's dependencies",
                       steps: [(locked ? INSTALL_LOCKED : INSTALL_FREE).fetch(manager)])
      end
      (missing - ["node_modules"]).each do |dir|
        argv = stack.setup[dir]
        out << Fix.new(id: "setup:#{dir}", label: "Create #{dir}/", steps: [argv]) if argv
      end
      wanted = packages.select { |p| p.match?(PACKAGE) }.uniq
      unless wanted.empty?
        out << Fix.new(id: "packages", label: "Install #{wanted.join(', ')}", steps: [ADD_DEV.fetch(manager) + wanted], commit: true)
      end
      out
    end

    # The dirty files of a project when they are all dependency files (package.json, lockfiles), else nil.
    # @param porcelain [String] git status --porcelain --untracked-files=all
    # @return [Array<String>, nil]
    def self.dependency_changes(porcelain)
      files = porcelain.lines.map { |l| l[3..].to_s.strip }.reject(&:empty?)
      return nil if files.empty? || !files.all? { |f| DEPENDENCY_FILES.include?(f) }

      files
    end

    # @param files [Array<String>] dependency files with uncommitted changes
    # @return [Fix] commit them, and only them
    def self.commit_fix(files)
      Fix.new(id: "commit-deps", label: "Commit the dependency changes (#{files.join(', ')})",
              steps: [["git", "add", "--", *files], ["git", "commit", "-m", "chore: install project dependencies", "--", *files]])
    end

    # What stops a build here, in words, or nil. Missing folders the stack has no fix for say what to do.
    # @param stack [Gates::Stack]
    # @param top [String]
    # @return [String, nil]
    def self.problem(stack, top)
      missing = missing_dirs(stack, top)
      return nil if missing.empty?

      "#{missing.join(', ')} #{missing.size == 1 ? 'is' : 'are'} missing: the project is not set up yet, so its checks cannot run"
    end

    # Run one fix in the project's folder.
    # @param fix [Fix]
    # @param top [String]
    # @param env [Hash{String=>String}] a scrubbed environment (Gates::Env)
    # @return [Array(Boolean, String)] success and the end of the output
    def self.run(fix, top, env)
      output = +""
      ok = run_steps(fix.steps, top, env, output)
      ok &&= commit_changes(top, env, output) if fix.commit
      [ok, output.lines.last(30).join[0, 4000]]
    end

    # The packages a new Astro project gets on top of the template, so its checks (astro check) can run on the
    # first build instead of asking for them.
    ASTRO_CHECK_PACKAGES = %w[@astrojs/check typescript].freeze

    # @return [Fix] add the packages astro check needs, with npm (the create command's package manager)
    def self.astro_check_fix
      Fix.new(id: "astro-check", label: "Install #{ASTRO_CHECK_PACKAGES.join(', ')}", steps: [ADD_DEV.fetch("npm") + ASTRO_CHECK_PACKAGES])
    end

    # @return [Boolean] every step succeeded; output gets each step's output
    def self.run_steps(steps, top, env, output)
      steps.each do |argv|
        r = run_one(argv, top, env)
        output << "#{r.stdout}\n#{r.stderr}".strip << "\n"
        return false unless r.success?
      rescue CommandNotFoundError
        output << "#{argv.first} was not found: install it first (for npm, install Node.js)\n"
        return false
      end
      true
    end

    # Commit what the steps changed when it is only dependency files; anything else is left for the person.
    # @return [Boolean]
    def self.commit_changes(top, env, output)
      porcelain = run_one(%w[git status --porcelain --untracked-files=all], top, env)
      return true if porcelain.success? && porcelain.stdout.strip.empty?

      files = porcelain.success? ? dependency_changes(porcelain.stdout) : nil
      unless files
        output << "Installed, but other files changed too, so nothing was committed: commit or undo them before a build.\n"
        return false
      end
      run_steps(commit_fix(files).steps, top, env, output)
    end

    # The one place a fix starts a process (I4).
    # @return [Exec::Result]
    def self.run_one(argv, top, env)
      Exec.run(argv, chdir: top, env: env, timeout: TIMEOUT, max_output: 131_072)
    end
    private_class_method :run_steps, :commit_changes, :run_one
  end
end
