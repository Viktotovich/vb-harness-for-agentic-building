# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# The app's project picker (DESIGN.md 11.3): pasted paths are validated, linked folders are stored by name in
# config.json, downloads run only after confirmation, and I2/I11 hold for linked folders: the build works in
# <home>/workspaces/<runId> and the linked checkout is never changed.

require_relative "test_helper"
require_relative "support/review_run"
require_relative "support/ui_client"
require "json"
require "tmpdir"

class ProjectsTest < Minitest::Test
  RR = TestSupport::ReviewRun
  F = TestSupport::RunFixture
  C = TestSupport::UIClient

  def setup
    @tmp = Dir.mktmpdir("harness-projects-")
    @home = File.join(@tmp, "harness")
    FileUtils.mkdir_p(@home)
    @config_path = File.join(@home, "config.json")
    File.write(@config_path, JSON.generate(RR.raw_config("http://127.0.0.1:9/v1")))
    @repo, @git_env = TestSupport.repo(@tmp, RR::FILES.merge("package-lock.json" => JSON.generate({ "packages" => { "node_modules/astro" => { "version" => "7.4.0" } } }),
                                                             "package.json" => JSON.generate({ "dependencies" => { "astro" => "^7.4.0" } })))
    @env = ENV.to_h.merge(@git_env).merge("HOME" => @tmp, "USERPROFILE" => @tmp)
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def projects
    Harness::Projects.new(home: @home, config_path: @config_path, config: Harness::Config.load(@config_path, env: @env), env: @env)
  end

  def test_a_clean_repository_is_described_without_its_absolute_path
    s = projects.status(@repo)
    assert_nil s.error
    assert_equal ["repo", "~/repo", true, "main", true, "astro", "7.4.0"], s.to_h.values_at(:name, :display, :git, :branch, :clean, :stack, :version)
    refute_includes s.display, @tmp.tr("\\", "/"), "the home folder is shown as ~"
  end

  def test_pasted_paths_are_validated_with_precise_errors
    sub = File.join(@repo, "src")
    plain = File.join(@tmp, "plain")
    FileUtils.mkdir_p(plain)
    {
      "" => "paste the folder's full path",
      "relative/path" => "use a full path",
      File.join(@tmp, "missing") => "no folder at that path",
      plain => "not a git repository",
      sub => "this folder is inside the repository ~/repo; use its top folder"
    }.each do |path, error|
      assert_includes projects.status(path).error.to_s, error, path.inspect
    end
    File.write(File.join(@repo, "notes.txt"), "draft")
    dirty = projects.status(@repo)
    assert_equal [false, "uncommitted changes: commit or stash them before a build"], [dirty.clean, dirty.error]
  end

  def test_linking_stores_a_name_in_config_and_refuses_the_harness_itself
    p = projects.link(@repo)
    assert_equal ["repo", true], [p.name, p.linked]
    stored = JSON.parse(File.read(@config_path))["projects"]
    assert_equal [{ "name" => "repo", "path" => File.realpath(@repo) }], stored
    assert_equal p, projects.link(@repo), "linking twice keeps one entry"
    other, = TestSupport.repo(File.join(@tmp, "b"), { "README.md" => "x\n" })
    assert_equal "repo-2", projects.link(other).name, "names stay unique"
    FileUtils.mkdir_p(File.join(@home, "workspaces", "r1"))
    err = assert_raises(Harness::ParseError) { projects.link(File.join(@home, "workspaces", "r1")) }
    assert_match(/part of the harness itself/, err.message)
    assert_raises(Harness::ParseError) { projects.link("relative") }
    projects.unlink("repo")
    assert_equal ["repo-2"], projects.list.map(&:name)
  end

  def test_own_projects_live_in_projects_and_show_short_paths
    own = File.join(@home, "projects", "site")
    FileUtils.mkdir_p(own)
    pr = projects
    assert_equal [["site", false]], pr.list.map { |p| [p.name, p.linked] }
    assert_equal "projects/site", pr.status(own).display
    long = "/srv/#{'x' * 80}/project"
    assert_operator pr.display(long).size, :<=, 48
    assert_includes pr.display(long), "…"
  end

  def test_clone_and_create_need_confirmation_and_name_the_exact_command
    plan = projects.clone_plan("https://example.com/owner/site.git")
    assert_equal ["clone", "git clone --depth 1 -- https://example.com/owner/site.git projects/site", "projects/site"], plan.to_h.values
    ["git@github.com:owner/site.git", "http://example.com/x.git", "file:///etc/x", "https://example.com/x.git --upload-pack=x",
     "-https://example.com/x", "ssh://example.com/x"].each do |url|
      assert_raises(Harness::ParseError, url) { projects.clone_plan(url) }
    end
    assert_raises(Harness::ParseError) { projects.clone_plan("https://example.com/x.git", "../escape") }
    create = projects.create_plan("my-site")
    assert_equal "projects/my-site", create.target
    assert_includes create.command, "npm create astro@latest my-site -- --template minimal --install --no-git --yes"
    assert_raises(Harness::ParseError) { projects.create_plan("bad name") }
  end

  def start_app
    app = Harness::UI::App.new(config_path: @config_path, token: "k" * 64, env: @env,
                               pipeline_for: ->(cfg, home) { Harness::Pipeline.new(config: cfg, home: home, env: @env, client_factory: ->(store) { F.client(cfg, store) }) })
    @server = Harness::UI::Server.new(app: app, port: 0, token: "k" * 64)
    @server.start
  end

  def test_the_app_runs_a_download_only_after_confirmation
    start_app
    port = @server.port
    first = C.post(port, "k" * 64, "/api/projects/clone", { "url" => "https://127.0.0.1:1/owner/site.git" })
    assert_equal 409, first.status
    assert_equal "git clone --depth 1 -- https://127.0.0.1:1/owner/site.git projects/site", first.json.dig("confirm", "command")
    refute Dir.exist?(File.join(@home, "projects", "site")), "nothing runs before confirmation"
    second = C.post(port, "k" * 64, "/api/projects/clone", { "url" => "https://127.0.0.1:1/owner/site.git", "confirm" => true })
    assert_equal 400, second.status, "the confirmed clone ran (and failed: nothing listens there)"
    assert_match(/git clone .*failed.*127.0.0.1:1/m, second.json["error"])
    assert_equal 409, C.post(port, "k" * 64, "/api/projects/create", { "name" => "my-site" }).status
    assert_equal 409, C.post(port, "k" * 64, "/api/projects/create", { "name" => "my-site", "confirm" => "true" }).status,
                 "only a JSON true confirms"
    assert_equal 400, C.post(port, "k" * 64, "/api/projects/clone", { "url" => "git@github.com:x/y.git", "confirm" => true }).status
    v = C.post(port, "k" * 64, "/api/projects/validate", { "path" => @tmp }).json
    assert_equal %w[branch clean display error git name stack version], v.keys.sort, "validation describes one folder; it never lists one"
  end

  # I2 and I11 for linked folders: the build happens in <home>/workspaces/<runId>; the linked checkout keeps its
  # branch, files and status.
  def test_a_build_in_a_linked_folder_never_touches_it
    server = F.server({ "plan" => F.plan_reply([F.task("T1", "Double the price", modify: ["src/lib/price.ts"])]),
                        "T1 implement" => F.replace("src/lib/price.ts", "  return n;", "  return n * 2;") })
    projects.link(@repo)
    head = TestSupport.git!(@repo, @git_env, "rev-parse", "HEAD")
    cfg = Harness::Config.load(@config_path, env: @env)
    cfg = Harness::Config.parse(JSON.parse(File.read(@config_path)).tap { |c| c["profiles"]["default"]["baseUrl"] = server.base_url })
    pipeline = Harness::Pipeline.new(config: cfg, home: @home, env: @env, client_factory: ->(store) { F.client(cfg, store) })
    result = pipeline.start(repo: projects.find("repo").path, request: "Double the price.")
    assert_equal "done", result.status
    run = Harness::State::RunStore.new(runs_dir: File.join(@home, "runs"), run_id: result.run_id).read_run
    assert File.identical?(File.join(@home, "workspaces", result.run_id), run["worktree"]), "the worktree is in the harness's workspaces/"
    assert_equal head, TestSupport.git!(@repo, @git_env, "rev-parse", "HEAD"), "the linked checkout's branch did not move"
    assert_empty TestSupport.git!(@repo, @git_env, "status", "--porcelain"), "the linked checkout is clean"
    assert_equal "export function price(n: number): number {\n  return n;\n}\n", File.read(File.join(@repo, "src/lib/price.ts"))
    refute Dir.exist?(File.join(@tmp, ".harness-worktrees")), "nothing is created next to the linked folder"
    assert_raises(Harness::PathError) { Harness::Repo::Paths.resolve_in_worktree(run["worktree"], "../repo/src/lib/price.ts") }
  ensure
    server&.stop
  end
end
