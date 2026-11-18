# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# One-click setup: which fixes a project gets, that they come only from code and the stack's config, and that the
# app runs one only after confirmation. Also the checks a new project cannot pass yet: no tests, missing packages.

require_relative "test_helper"
require "json"
require "tmpdir"

class ProjectSetupTest < Minitest::Test
  PS = Harness::ProjectSetup

  def setup
    @tmp = Dir.mktmpdir("harness-setup-")
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def stack(extra = {})
    Harness::Gates::Stack.parse("astro", { "detect" => ["astro.config.mjs"], "dependencyDirs" => %w[node_modules generated],
                                           "gates" => {} }.merge(extra))
  end

  def test_fixes_follow_what_is_missing_and_the_lockfile
    File.write(File.join(@tmp, "package.json"), "{}")
    s = stack("setup" => { "generated" => %w[npx --no -- prisma generate] })
    assert_equal ["install", "setup:generated"], PS.fixes(s, @tmp).map(&:id)
    assert_equal "npm install --no-package-lock --ignore-scripts", PS.fixes(s, @tmp).first.command,
                 "no lockfile: the install does not write one, so the project stays clean"
    File.write(File.join(@tmp, "package-lock.json"), "{}")
    assert_equal [%w[npm ci --ignore-scripts]], PS.fixes(s, @tmp).first.steps, "a lockfile is installed exactly, unchanged"
    File.delete(File.join(@tmp, "package-lock.json"))
    File.write(File.join(@tmp, "pnpm-lock.yaml"), "")
    assert_equal [%w[pnpm install --frozen-lockfile --ignore-scripts]], PS.fixes(s, @tmp).first.steps
    assert_match(/node_modules, generated are missing/, PS.problem(s, @tmp))

    FileUtils.mkdir_p(File.join(@tmp, "node_modules"))
    FileUtils.mkdir_p(File.join(@tmp, "generated"))
    assert_nil PS.problem(s, @tmp)
    fixes = PS.fixes(s, @tmp, packages: ["@astrojs/check", "typescript", "bad name; rm -rf /", "-e"])
    assert_equal [[%w[pnpm add -D --ignore-scripts @astrojs/check typescript]]], fixes.map(&:steps), "only valid package names"
    assert_equal({ "id" => "packages", "label" => "Install @astrojs/check, typescript",
                   "command" => "pnpm add -D --ignore-scripts @astrojs/check typescript" }, fixes.first.to_json_hash)
    assert_empty PS.fixes(stack, @tmp), "nothing missing, nothing asked for"
  end

  def test_only_dependency_files_left_uncommitted_get_a_commit_fix
    assert_equal %w[package.json package-lock.json], PS.dependency_changes(" M package.json\n?? package-lock.json\n")
    assert_nil PS.dependency_changes(" M package.json\n M src/index.astro\n"), "other changes are the user's to commit"
    assert_nil PS.dependency_changes("")
    fix = PS.commit_fix(%w[package.json package-lock.json])
    assert_equal "git add -- package.json package-lock.json && git commit -m \"chore: install project dependencies\" -- package.json package-lock.json",
                 fix.command
  end

  def test_setup_commands_are_config_and_checked
    assert_raises(Harness::ParseError) { stack("setup" => { "dist" => %w[npm run build] }) }
    assert_raises(Harness::ParseError) { stack("setup" => { "generated" => [] }) }
    assert_raises(Harness::ParseError) { stack("setup" => { "generated" => "npx prisma generate" }) }
    assert_raises(Harness::ParseError) { stack("preview" => %w[npx astro dev]) }
    assert_equal %w[npx astro dev --port {port}], stack("preview" => %w[npx astro dev --port {port}]).preview
    assert_nil stack.preview
  end

  def test_packages_come_from_skip_reasons
    reasons = [nil, "tool not installed: x", "#{PS::NEEDS}@astrojs/check, typescript", "#{PS::NEEDS}typescript"]
    assert_equal ["@astrojs/check", "typescript"], PS.packages_from(reasons)
  end

  def test_a_new_project_without_tests_or_with_missing_packages_is_skipped_not_failed
    runner = Harness::Gates::Runner.new(root: @tmp, env: ENV.to_h.slice("PATH", "SystemRoot", "PATHEXT"))
    gate = ->(script) { Harness::Gates::Gate.parse("unit", { "argv" => [RbConfig.ruby, "-e", script] }, "g") }
    r = runner.run(gate.call('puts "No test files found, exiting with code 1"; exit 1'))
    assert_equal ["skipped", "the project has no tests yet"], [r.status, r.reason.split(":").first]
    r = runner.run(gate.call('puts "To continue, Astro requires the following dependency to be installed: \e[1m@astrojs/check\e[22m."; ' \
                             'puts "To continue, Astro requires the following dependency to be installed: typescript."; exit 1'))
    assert_equal ["skipped", "#{PS::NEEDS}@astrojs/check, typescript"], [r.status, r.reason]
    assert_equal "failed", runner.run(gate.call('puts "src/x.ts(1,1): error TS2322"; exit 1')).status
  end

  def test_a_fix_runs_in_the_project_folder
    s = stack("setup" => { "generated" => [RbConfig.ruby, "-e", "Dir.mkdir('generated'); puts 'made it'"] })
    FileUtils.mkdir_p(File.join(@tmp, "node_modules"))
    fix = PS.fixes(s, @tmp).first
    ok, out = PS.run(fix, @tmp, ENV.to_h.slice("PATH", "SystemRoot", "PATHEXT"))
    assert ok
    assert_includes out, "made it"
    assert File.directory?(File.join(@tmp, "generated"))
    assert_empty PS.fixes(s, @tmp)
  end
end
