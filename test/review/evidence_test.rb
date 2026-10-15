# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Ported from REVIEWER test/evidence.test.js (local docs, version, retriever). Online docs and the dataset are
# not ported.

require_relative "../test_helper"
require_relative "../support/review_fixture"
require "json"
require "tmpdir"

class EvidenceTest < Minitest::Test
  RF = TestSupport::ReviewFixture
  E = Harness::Evidence

  def setup
    @tmp = Dir.mktmpdir("harness-evidence-")
    @docs = E::LocalDocs.load(root: RF.docs(File.join(@tmp, "docs")), cache_dir: File.join(@tmp, "cache"))
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def fw(known:, major: nil)
    E::Framework.new(known: known, name: "Astro", package: "astro", declared: "^#{major}", installed: nil, major: major,
                     source: "package.json (range)", notes: [])
  end

  def test_local_docs_sections_line_ranges_and_version_from_since_without_pkg
    s = E::LocalDocs.sectionize("en/basics/astro-components.mdx", RF::HTML_COMPONENTS)
    assert_equal ["HTML Components"], s.map { |x| x["heading"] }, "headings inside code fences are ignored"
    assert_operator s[0]["lineStart"], :>=, 6
    assert_equal "7.3.0", @docs.documents_up_to, "integration versions (pkg=...) are ignored"
    assert_equal 7, @docs.major
    assert_equal "basics/astro-components", @docs.search("slot html component is:inline", 1).first.doc["slug"]
  end

  def test_tokens_keep_identifiers_whole_and_index_their_parts
    assert_equal %w[is:inline inline astro.props astro props], E::TextIndex.tokenize("is:inline Astro.props the"), "stop words such as is and the are dropped"
  end

  def test_version_lockfile_wins_and_ranges_pin_one_major_only
    assert_equal "7.3.2", E::Version.parse_lock("package-lock.json", JSON.generate({ "packages" => { "node_modules/astro" => { "version" => "7.3.2" } } }), "astro")
    assert_equal "6.4.8", E::Version.parse_lock("yarn.lock", "astro@^6.1.0:\n  version \"6.4.8\"\n", "astro")
    assert_equal [7, 6, nil, nil], ["^7.3.2", ">=6.0.0 <7.0.0", "*", "6 || 7"].map { |r| E::Version.major_from_range(r) }

    repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p(repo)
    File.write(File.join(repo, "package.json"), JSON.generate({ "dependencies" => { "astro" => "*" } }))
    v = E::Version.detect(repo, name: "Astro", package: "astro")
    refute v.known
    assert_match(/version UNKNOWN/, v.line)
    File.write(File.join(repo, "package-lock.json"), JSON.generate({ "packages" => { "node_modules/astro" => { "version" => "7.1.0" } } }))
    v = E::Version.detect(repo, name: "Astro", package: "astro")
    assert_equal [true, 7, "Framework: Astro 7.1.0 (from package-lock.json, declared *)"], [v.known, v.major, v.line]
  end

  def test_retriever_version_matched_when_the_repo_uses_the_documented_major
    r = E::Retriever.new(framework: fw(known: true, major: 7), local_docs: @docs)
    res = r.lookup(query: "slot inside HTML component is:inline")
    assert_equal [true, "E1"], [res.evidence[0].version_matched, res.evidence[0].id]
    assert_match(%r{basics/astro-components\.mdx#L\d+-L\d+}, res.evidence[0].ref)
    assert_includes res.evidence[0].excerpt, "add `is:inline` to your `<slot>` element"
    assert_same res.evidence[0], r.get("E1")
  end

  def test_retriever_labels_other_versions_and_states_what_is_missing
    old = E::Retriever.new(framework: fw(known: true, major: 6), local_docs: @docs).lookup(query: "slot inside HTML component is:inline")
    refute_empty old.evidence
    assert(old.evidence.none?(&:version_matched))
    assert(old.notes.any? { |n| n.include?("not evidence for 6") })

    unknown = E::Retriever.new(framework: fw(known: false), local_docs: @docs)
    assert(unknown.lookup(query: "client:only framework value").notes.any? { |n| n.include?("version unknown") })
    none = unknown.lookup(query: "kubernetes helm chart ingress")
    assert_equal [[], true], [none.evidence, none.notes.include?("no relevant evidence found")]
    assert_match(/rejected query/, unknown.lookup(query: "https://evil.example/x").notes.join)
  end

  def test_the_index_is_cached_per_docs_commit
    root = File.join(@tmp, "docs")
    FileUtils.mkdir_p(File.join(root, ".git"))
    File.write(File.join(root, ".git", "HEAD"), "#{'a' * 40}\n")
    E::LocalDocs.load(root: root, cache_dir: File.join(@tmp, "c2"))
    assert File.file?(File.join(@tmp, "c2", "docs-local-aaaaaaaaaaaa.json"))
  end
end
