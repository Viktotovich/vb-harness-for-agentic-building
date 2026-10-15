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
end
