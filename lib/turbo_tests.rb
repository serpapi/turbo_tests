# frozen_string_literal: true

require "securerandom"
require "open3"
require "fileutils"
require "json"

require "rspec"

require "parallel_tests"
require "parallel_tests/rspec/runner"

require "turbo_tests/version"
require "turbo_tests/protocol"
require "turbo_tests/fake_example"
require "turbo_tests/reporter"
require "turbo_tests/runner"
require "turbo_tests/json_rows_formatter"

module TurboTests
  autoload :CLI, "turbo_tests/cli"
end
