# frozen_string_literal: true

require "fileutils"
require "json"

require "rspec/core"

require "turbo_tests/version"
require "turbo_tests/options"
require "turbo_tests/protocol"
require "turbo_tests/files"
require "turbo_tests/runtime_log"
require "turbo_tests/scheduler"
require "turbo_tests/hooks"
require "turbo_tests/env_number"
require "turbo_tests/diagnostics"
require "turbo_tests/fake_example"
require "turbo_tests/reporter"
require "turbo_tests/json_rows_formatter"
require "turbo_tests/worker"
require "turbo_tests/pool/base"
require "turbo_tests/pool/spawn"
require "turbo_tests/pool/fork"
require "turbo_tests/pool/command"
require "turbo_tests/supervisor"
require "turbo_tests/runner"

module TurboTests
  Error = Class.new(StandardError) unless const_defined?(:Error, false)

  autoload :CLI, "turbo_tests/cli"
end
