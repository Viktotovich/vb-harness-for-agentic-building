# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  # Base class for every error the harness raises on purpose.
  class Error < StandardError; end

  # A shape from outside (model JSON, config, cache, run state) did not match what its parser expects.
  # The message names the exact location, e.g. "tasks[2].files.modify: expected array of strings, got nil".
  class ParseError < Error; end

  # A subprocess could not be started because its executable was not found.
  class CommandNotFoundError < Error; end

  # An argument was refused before reaching a subprocess (e.g. a cmd.exe metacharacter for a batch file).
  class UnsafeArgumentError < Error; end

  # The server answered, but the answer is unusable (empty, cut off, not JSON, wrong shape).
  # The stage fails; the run goes on.
  class ModelOutputError < Error
    # @return [String] a reason code from DESIGN.md section 10.3, e.g. "model.invalid_json"
    attr_reader :reason

    # @param message [String]
    # @param reason [String]
    def initialize(message, reason:)
      super(message)
      @reason = reason
    end
  end

  # The model server is down, busy or misconfigured (connection refused, timeout, HTTP 429/503, other errors).
  class ModelUnavailableError < Error; end

  # The request does not fit the model's context. Callers trim or split; the client never trims silently.
  class ContextOverflowError < Error; end

  # A task's required context (intent, acceptance, files) does not fit; the planner must split it.
  class TaskTooLargeError < Error; end

  # A path was refused before any read or write (I2): outside the worktree, absolute, or protected.
  class PathError < Error
    # @return [String] a reason code, "edit.outside_worktree" or "edit.protected_path"
    attr_reader :reason

    # @param message [String]
    # @param reason [String]
    def initialize(message, reason:)
      super(message)
      @reason = reason
    end
  end

  # A git command failed, or was not on the allowlist (DESIGN.md 9.2).
  class GitError < Error; end
end
