# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "securerandom"

module Harness
  module Repo
    # Every file the harness writes in a worktree goes through here: the content goes to a temporary file in the
    # same folder, which is then renamed over the target. A rename replaces the directory entry, so a target that
    # is a hard link (a mirrored dependency file, Repo::Mirror) gets a new file and the user's original is never
    # written through the link (I11).
    module AtomicFile
      # @param path [String]
      # @param content [String] written as bytes
      # @return [void]
      def self.write(path, content)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = File.join(File.dirname(path), ".#{File.basename(path)}.harness-#{SecureRandom.hex(4)}.tmp")
        File.binwrite(tmp, content)
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end
    end
  end
end
