# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "erb"
require_relative "errors"

module Harness
  # Renders prompts/<name>.md.erb with a plain Hash of locals (DESIGN.md 4.5). Templates hold no logic beyond
  # output tags and simple each; untrusted text arrives already fenced. The profile's promptNotes are appended
  # by the model client, last.
  module Prompts
    DIR = File.expand_path("../../prompts", __dir__)
    NAME = /\A[a-z][a-z0-9_]{0,40}\z/

    # @param name [String] template name without extension, e.g. "implement_system"
    # @param locals [Hash{Symbol=>Object}]
    # @return [String]
    # @raise [ArgumentError] on an unknown template name
    def self.render(name, **locals)
      raise ArgumentError, "prompt name #{name.inspect}" unless name.match?(NAME)

      path = File.join(DIR, "#{name}.md.erb")
      raise ArgumentError, "no prompt template #{name}" unless File.file?(path)

      ERB.new(File.read(path, encoding: "UTF-8"), trim_mode: "-").result_with_hash(locals).strip
    end
  end
end
