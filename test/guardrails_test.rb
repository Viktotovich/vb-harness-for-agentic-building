# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Hard invariants (DESIGN.md section 1). Never weaken or delete these tests; if one blocks
# you, stop and ask. Invariants not yet implemented are added with their milestone.

require_relative "test_helper"
require_relative "support/guard_scan"
require_relative "support/fake_llm_server"
require "tmpdir"

class GuardrailsTest < Minitest::Test
  Scan = TestSupport::GuardScan
  ROOT = TestSupport::ROOT

  def read(rel)
    File.read(File.join(ROOT, rel), mode: "rb").force_encoding(Encoding::UTF_8).scrub
  end

  def report(hits)
    hits.map { |h| "#{h.file}:#{h.line} [#{h.rule}] #{h.text}" }.join("\n")
  end

  # Files that would be committed: tracked plus untracked-but-not-ignored. Falls back to a
  # directory walk (minus .git and ignored run data) when git is unavailable.
  def committable_files
    r = Harness::Exec.run(%w[git ls-files -z --cached --others --exclude-standard],
                          chdir: ROOT, env: TestSupport.child_env, timeout: 60)
    return r.stdout.split("\0").reject(&:empty?).select { |f| File.file?(File.join(ROOT, f)) } if r.success?

    walk_files
  rescue Harness::CommandNotFoundError
    walk_files
  end

  def walk_files
    skip_re = %r{\A(?:\.git|runs|logs|\.cache|chats)/|\Aconfig\.json\z}
    Dir.glob("**/*", File::FNM_DOTMATCH, base: ROOT).select { |f| File.file?(File.join(ROOT, f)) }.grep_v(skip_re)
  end

  # --- I1: no model names in lib/ or prompts/ ---

  def test_i1_lib_and_prompts_name_no_model
    hits = Scan.files_in(ROOT, %w[lib prompts]).flat_map { |f| Scan.model_name_hits(read(f), f) }
    assert_empty hits, "I1: model-specific names found:\n#{report(hits)}"
  end

  def test_i1_scanner_detects_every_denylisted_word
    Scan::MODEL_WORDS.each do |w|
      refute_empty Scan.model_name_hits("default = \"#{w.capitalize}-7B\"\n", "x.rb"), "missed #{w}"
    end
    assert_empty Scan.model_name_hits("provider = :ollama\n", "x.rb"), "a provider name is not a model name"
  end

  # --- I3: subprocesses only through Harness::Exec ---

  def test_i3_no_process_calls_outside_exec
    hits = Scan.files_in(ROOT, %w[lib exe bin]).flat_map { |f| Scan.shell_hits(read(f), f) }
    assert_empty hits, "I3: process calls outside Harness::Exec:\n#{report(hits)}"
  end

  def test_i3_exec_uses_only_popen3_with_argv_array
    src = read(Scan::EXEC_FILE)
    calls = src.scan(/Open3\.(\w+)\(([^,]+),\s*(\S)/)
    refute_empty calls, "exec.rb must call Open3.popen3"
    calls.each do |meth, _env, first|
      assert_equal "popen3", meth
      assert_equal "[", first, "Open3.popen3 must receive the command as an array, not a string"
    end
  end

  def test_i3_scanner_detects_shell_outs
    samples = [
      "out = `ls`", "x = %x(ls)", "system(\"ls\")", "system \"ls -la\"", "Kernel.system(cmd)",
      "exec(\"ls\")", "spawn(cmd)", "Process.spawn(\"ls\")", "IO.popen(cmd)", "Open3.capture2(cmd)",
      "open(\"|ls\")", "IO.read(\"|ls\")", "pid = fork { }"
    ]
    samples.each { |s| refute_empty Scan.shell_hits("#{s}\n", "lib/x.rb"), "missed: #{s}" }
    clean = "msgs = Messages.new(system: \"You review code.\", user: u)\nrole = \"system\"\nExec.run(argv)\n"
    assert_empty Scan.shell_hits(clean, "lib/x.rb"), "false positive on role names"
  end

  # --- I12: keys only from apiKeyEnv; never in records, logs, caches or error messages ---

  def test_i12_key_is_sent_but_never_recorded_logged_or_cached
    key = "harness-i12-#{'k' * 24}"
    env = { "TEST_HARNESS_KEY" => key }
    incomplete = TestSupport::FakeLlmServer.error(502, "structured output was incomplete (finish_reason=length)")
    srv = TestSupport::FakeLlmServer.new(replies: [incomplete, TestSupport::FakeLlmServer.ok("{}"),
                                                   TestSupport::FakeLlmServer.error(500, "engine crashed")])
    Dir.mktmpdir("harness-i12-") do |dir|
      client = TestSupport.client(srv.base_url, dir, profile: { "apiKeyEnv" => "TEST_HARNESS_KEY" }, env: env)
      msgs = Harness::Model::Messages.new(system: "s", user: "u")
      client.complete(:planner, msgs, label: "plan", parser: ->(v) { v })
      err = assert_raises(Harness::ModelUnavailableError) { client.complete(:planner, msgs, label: "plan2") }
      refute_includes err.message, key

      config = TestSupport.config(srv.base_url, apiKeyEnv: "TEST_HARNESS_KEY")
      Harness::Model::Probe.new(http: Harness::Model::Http.new, cache_dir: File.join(dir, "cache"), env: env, timeout: 10)
                           .call(config.profiles["default"])

      assert(srv.requests.all? { |r| r.headers["authorization"] == "Bearer #{key}" }, "every request carries the key")
      files = Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }
      assert_operator files.size, :>=, 4, "records, a log and a probe cache were written"
      leaks = files.select { |f| File.read(f, mode: "rb").include?(key) }
      assert_empty leaks, "I12: the key leaked into #{leaks.join(', ')}"
    end
  ensure
    srv&.stop
  end

  def test_i12_without_api_key_env_no_authorization_header_is_sent
    srv = TestSupport::FakeLlmServer.new(replies: [TestSupport::FakeLlmServer.ok("hi")])
    Dir.mktmpdir("harness-i12-") do |dir|
      TestSupport.client(srv.base_url, dir, env: { "OPENAI_API_KEY" => "should-not-be-used" })
                 .complete(:planner, Harness::Model::Messages.new(system: "s", user: "u"), label: "chat")
    end
    assert_nil srv.requests.last.headers["authorization"], "keys come only from the variable apiKeyEnv names"
  ensure
    srv&.stop
  end

  # --- I13: nothing personal or secret in committed files ---

  def test_i13_no_home_paths_or_secrets_in_committed_files
    hits = committable_files.flat_map { |f| Scan.leak_hits(read(f), f) }
    assert_empty hits, "I13: personal paths or secrets:\n#{report(hits)}"
  end

  def test_i13_scanner_detects_leaks
    samples = [
      "C:" + "\\Users\\someone\\x", "C:" + "\\\\Users\\\\someone", "/ho" + "me/someone/x", "/Us" + "ers/someone/x",
      "gh" + "p_abcdefghijklmnopqrstu", "github" + "_pat_11ABCDEFGHIJ", "s" + "k-abcdefghijklmnopqrstuv",
      "AK" + "IAABCDEFGHIJKLMNOP", "-----" + "BEGIN RSA PRIVATE KEY-----"
    ]
    samples.each { |s| refute_empty Scan.leak_hits("#{s}\n", "f"), "missed: #{s}" }
    assert_empty Scan.leak_hits("task-123 and risk-free disk-usage\n", "f")
  end

  def test_i13_gitignore_lists_run_data_and_local_config
    lines = read(".gitignore").lines.map(&:strip)
    %w[runs/ logs/ .cache/ config.json chats/].each { |entry| assert_includes lines, entry }
  end

  # --- I14: zero gem dependencies ---

  def test_i14_no_gemfile_with_gems
    gemfile = File.join(ROOT, "Gemfile")
    gems = File.exist?(gemfile) ? File.readlines(gemfile).grep(/^\s*gem\s/) : []
    assert_empty gems, "I14: Gemfile declares gems"
  end

  def test_i14_gemspec_declares_no_dependencies
    spec = read("vb-harness.gemspec")
    refute_match(/add_(?:runtime_|development_)?dependency/, spec, "I14: gemspec declares a dependency")
  end

  def test_i14_requires_are_on_the_allowlist
    hits = Scan.files_in(ROOT, %w[lib exe bin test]).flat_map { |f| Scan.require_hits(read(f), f) }
    assert_empty hits, "I14: requires outside the allowlist:\n#{report(hits)}"
  end

  def test_i14_scanner_flags_gems_and_dynamic_requires
    refute_empty Scan.require_hits("require \"nokogiri\"\n", "f")
    refute_empty Scan.require_hits("require name\n", "f")
    assert_empty Scan.require_hits("require \"json\"\nrequire_relative \"x\"\n", "f")
  end

  # --- Section 16: SPDX header on every source file ---

  def test_every_source_file_has_the_license_header
    files = Scan.files_in(ROOT, %w[lib test bin]).grep(/\.rb\z|\Abin\//) + Scan.files_in(ROOT, %w[exe])
    missing = files.reject do |f|
      head = read(f).lines.first(5).join
      head.include?("# frozen_string_literal: true") &&
        head.include?("# SPDX-License-Identifier: Apache-2.0") &&
        head.include?("# Copyright 2026 V and Bruno LLC")
    end
    assert_empty missing, "files without the header from DESIGN.md section 16:\n#{missing.join("\n")}"
  end
end
