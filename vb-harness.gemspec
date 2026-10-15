# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "lib/harness/version"

Gem::Specification.new do |s|
  s.name = "vb-harness"
  s.version = Harness::VERSION
  s.summary = "Local-first harness that gets real coding work out of local models."
  s.description = "Plans a feature as small tasks, has a local model implement them one at a time, and proves " \
                  "every change with the project's own checks. Zero dependencies."
  s.authors = ["V and Bruno LLC"]
  s.homepage = "https://github.com/Viktotovich/vb-harness-for-agentic-building"
  s.license = "Apache-2.0"
  s.required_ruby_version = ">= 3.3"
  s.files = Dir.glob(%w[exe/* lib/**/* prompts/**/* LICENSE NOTICE README.md config.example.json],
                     base: __dir__).select { |f| File.file?(File.join(__dir__, f)) }
  s.bindir = "exe"
  s.executables = ["harness"]
  s.require_paths = ["lib"]
  s.metadata = { "rubygems_mfa_required" => "true", "source_code_uri" => s.homepage }
  # No runtime or development dependencies (I14).
end
