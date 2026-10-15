# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# ruby eval/run_eval.rb [--profile-map FILE] [--tasks GLOB] [--config FILE] [--keep] [--json]
# The same as `harness eval`: runs every eval task under each profile mapping and prints a markdown table per
# mapping. See eval/README.md.

require_relative "../lib/harness"

exit Harness::CLI.run(["eval", *ARGV])
