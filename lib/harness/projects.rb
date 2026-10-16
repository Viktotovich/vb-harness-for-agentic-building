# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"
require_relative "config"
require_relative "errors"
require_relative "evidence/version"
require_relative "exec"
require_relative "gates/env"
require_relative "repo/git"
require_relative "state/records"

module Harness
  # The projects the app builds in (DESIGN.md 11.3): folders under <home>/projects/ (git-ignored), and folders the
  # user linked once, stored by name in config.json. The app never browses the disk: a folder is pasted and
  # validated. Labels are project names; paths are shown short (projects/<name>, or ~ for the home folder).
  class Projects
    NAME = Config::PROJECT_NAME
    # A project. linked: it lives outside projects/ and is remembered in config.json.
    Project = Data.define(:name, :path, :linked)
    # What the picker shows under the selected project. error is set when it cannot be built in.
    Status = Data.define(:name, :display, :git, :branch, :clean, :stack, :version, :error) do
      # @return [Hash]
      def to_json_hash = to_h.transform_keys(&:to_s)
    end
    # What a download or install would do, shown in the confirm dialog before it runs.
    Plan = Data.define(:action, :command, :target)

    CREATE_ASTRO = ->(name) { ["npm", "create", "astro@latest", name, "--", "--template", "minimal", "--install", "--no-git", "--yes"] }

    # @param home [String] the harness folder (next to config.json)
    # @param config_path [String]
    # @param config [Config, nil]
    # @param env [Hash{String=>String}]
    def initialize(home:, config_path:, config:, env:)
      @home = File.expand_path(home)
      @dir = File.join(@home, "projects")
      @config_path = config_path
      @config = config
      @env = env
    end

    # @return [Array<Project>] by name
    def list
      own = Dir.exist?(@dir) ? Dir.children(@dir).select { |d| d.match?(NAME) && File.directory?(File.join(@dir, d)) } : []
      found = own.map { |d| Project.new(name: d, path: File.join(@dir, d), linked: false) }
      linked = linked_projects.map { |n, p| Project.new(name: n, path: p, linked: true) }
      (found + linked.reject { |l| own.include?(l.name) }).sort_by(&:name)
    end

    # @param name [String]
    # @return [Project]
    # @raise [ConfigError]
    def find(name)
      list.find { |p| p.name == name } || raise(ConfigError, "no project named #{name.to_s[0, 64]}")
    end

    # Check a folder for building: a git repository at its top level, its branch, clean or not, and its stack.
    # @param path [String]
    # @return [Status]
    def status(path, name: nil)
      base = { name: name || File.basename(path.to_s), display: display(path.to_s), git: false, branch: nil, clean: nil,
               stack: nil, version: nil }
      problem = path_problem(path)
      return Status.new(**base, error: problem) if problem

      top = git.run(%w[rev-parse --show-toplevel], chdir: path).strip
      unless same_dir?(top, path)
        return Status.new(**base, git: true, error: "this folder is inside the repository #{display(top)}; use its top folder")
      end

      branch = git.run(%w[rev-parse --abbrev-ref HEAD], chdir: path).strip
      clean = git.run(%w[status --porcelain --untracked-files=all], chdir: path).strip.empty?
      stack = @config&.stacks&.values&.find { |s| s.detect.any? { |f| File.exist?(File.join(path, f)) } }
      version = stack && Evidence::Version.detect(path, name: stack.framework["name"] || stack.name,
                                                          package: stack.framework["lockfilePackage"] || stack.name)
      Status.new(**base, git: true, branch: branch, clean: clean, stack: stack&.name,
                         version: version&.known ? (version.installed || "#{version.major}.x") : nil,
                         error: clean ? nil : "uncommitted changes: commit or stash them before a build")
    rescue GitError => e
      Status.new(**base, error: e.message.include?("not a git repository") ? "not a git repository (run git init and commit first)" : e.message[0, 200])
    end

    # Remember a folder outside projects/ by name.
    # @param path [String] absolute
    # @return [Project]
    # @raise [ParseError] when the folder cannot be used
    def link(path)
      problem = path_problem(path)
      raise ParseError, problem if problem

      real = File.realpath(path)
      raise ParseError, "that folder is part of the harness itself; link a project folder" if inside?(real, @home)

      existing = list.find { |p| p.linked && same_dir?(p.path, real) }
      return existing if existing

      name = unique(File.basename(real).gsub(/[^A-Za-z0-9._-]/, "-").sub(/\A[^A-Za-z0-9]+/, "")[0, 64])
      update_config { |cfg| (cfg["projects"] ||= []) << { "name" => name, "path" => real } }
      Project.new(name: name, path: real, linked: true)
    end

    # @param name [String]
    # @return [void]
    def unlink(name)
      update_config { |cfg| cfg["projects"] = Array(cfg["projects"]).reject { |p| p["name"] == name } }
    end

    # @param url [String]
    # @param name [String, nil] defaults to the repository's name
    # @return [Plan]
    # @raise [ParseError]
    def clone_plan(url, name = nil)
      url = url.to_s.strip
      raise ParseError, "only https URLs can be cloned, such as https://github.com/owner/repo.git" unless url.match?(Repo::Git::CLONE_URL)

      name = new_name(name.to_s.empty? ? File.basename(url, ".git") : name)
      Plan.new(action: "clone", command: "git clone --depth 1 -- #{url} projects/#{name}", target: "projects/#{name}")
    end

    # Download a repository into projects/<name>. Only after the user confirmed the plan in the app.
    # @return [Project]
    # @raise [ParseError, GitError]
    def clone(url, name = nil)
      plan = clone_plan(url, name)
      FileUtils.mkdir_p(@dir)
      git.run(["clone", "--depth", "1", "--", url.to_s.strip, plan.target], chdir: @home)
      find(File.basename(plan.target))
    end

    # @param name [String]
    # @return [Plan]
    # @raise [ParseError]
    def create_plan(name)
      name = new_name(name)
      Plan.new(action: "create", command: "#{CREATE_ASTRO.call(name).join(' ')}   (in projects/), then git init and a first commit",
               target: "projects/#{name}")
    end

    # A new Astro project in projects/<name>: npm's create-astro (a download and an install, I10), then a git
    # repository with a first commit. Only after the user confirmed the plan in the app.
    # @return [Project]
    # @raise [ParseError, GitError, ConfigError]
    def create_astro(name)
      plan = create_plan(name)
      name = File.basename(plan.target)
      FileUtils.mkdir_p(@dir)
      r = Exec.run(CREATE_ASTRO.call(name), chdir: @dir, env: @env.to_h, timeout: 900, max_output: 65_536)
      raise ConfigError, "npm create astro failed: #{"#{r.stdout}\n#{r.stderr}".strip.lines.last(5).join.strip[0, 400]}" unless r.success?

      path = File.join(@dir, name)
      File.write(File.join(path, ".gitignore"), "node_modules/\ndist/\n.astro/\n") unless File.exist?(File.join(path, ".gitignore"))
      git.run(%w[init -q -b main], chdir: path)
      git.run(%w[add -A], chdir: path)
      git.run(["commit", "--no-verify", "-m", "New Astro project"], chdir: path)
      find(name)
    rescue CommandNotFoundError
      raise ConfigError, "npm was not found: install Node.js first"
    end

    # A path for people: projects/<name>, ~/... for the home folder, the middle cut when long.
    # @param path [String]
    # @return [String]
    def display(path)
      p = path.to_s.tr("\\", "/").chomp("/")
      home = (@env["USERPROFILE"] || @env["HOME"]).to_s
      if (rest = below(p, @home))
        p = rest
      elsif !home.empty? && (rest = below(p, home))
        p = "~/#{rest}"
      end
      p.size > 48 ? "#{p[0, 18]}…#{p[-27..]}" : p
    end

    private

    # @return [String, nil] why a pasted path cannot be a project
    def path_problem(path)
      return "paste the folder's full path" unless path.is_a?(String) && !path.strip.empty?
      return "use a full path, starting at the drive or /" unless absolute?(path)
      return "no folder at that path" unless File.directory?(path)

      nil
    end

    def absolute?(path) = path.start_with?("/") || path.match?(%r{\A[A-Za-z]:[\\/]})

    # The part of path below base, found by walking up path's folders and comparing each with base on disk, so
    # different spellings of one folder (Windows short names, case) match. nil when path is not below base.
    def below(path, base)
      return nil unless File.directory?(base)

      parts = path.split("/")
      (parts.size - 1).downto(1) do |n|
        anc = parts.first(n).join("/")
        anc = "/" if anc.empty?
        return parts.drop(n).join("/") if File.directory?(anc) && File.identical?(anc, base)
      end
      nil
    end

    def same_dir?(a, b)
      File.identical?(a, b)
    rescue SystemCallError
      false
    end

    def inside?(real, root)
      root_real = File.realpath(root)
      real.casecmp?(root_real) || real.downcase.start_with?("#{root_real.downcase}/") || real.downcase.start_with?("#{root_real.downcase}\\")
    rescue SystemCallError
      false
    end

    # @raise [ParseError]
    def new_name(name)
      n = name.to_s.strip
      raise ParseError, "a project name of letters, digits, . _ - (up to 64)" unless n.match?(NAME)
      raise ParseError, "a project named #{n} already exists" if list.any? { |p| p.name == n } || File.exist?(File.join(@dir, n))

      n
    end

    def unique(base)
      base = "project" if base.empty?
      names = list.map(&:name)
      return base unless names.include?(base)

      (2..).each { |i| return "#{base}-#{i}" unless names.include?("#{base}-#{i}") }
    end

    # Linked projects as config.json has them now (the app links folders while it runs).
    # @return [Hash{String=>String}]
    def linked_projects
      return @config&.projects || {} unless File.file?(@config_path)

      Config.parse(JSON.parse(File.read(@config_path, encoding: "UTF-8")), env: @env).projects
    rescue JSON::ParserError
      {}
    end

    def update_config
      cfg = JSON.parse(File.read(@config_path, encoding: "UTF-8"))
      yield cfg
      Config.parse(cfg)
      State.write_json(@config_path, cfg)
    rescue Errno::ENOENT
      raise ParseError, "set up a model provider first (Settings), then link projects"
    end

    def git
      env = Gates::Env.build(@env, allow: @config&.gate_env_allow || []).merge("GIT_TERMINAL_PROMPT" => "0")
      Repo::Git.new(env: env, cache_dir: File.join(@home, ".cache"), timeout: 600)
    end
  end
end
