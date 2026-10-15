# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "harness/version"
require_relative "harness/errors"
require_relative "harness/parse"
require_relative "harness/sha256"
require_relative "harness/exec"
require_relative "harness/log"
require_relative "harness/config"
require_relative "harness/state/records"
require_relative "harness/model/profiles"
require_relative "harness/model/tokens"
require_relative "harness/model/wire"
require_relative "harness/model/http"
require_relative "harness/model/probe"
require_relative "harness/model/client"
require_relative "harness/cli"

# Local-first harness that gets real coding work out of local models. See README.md.
module Harness
end
