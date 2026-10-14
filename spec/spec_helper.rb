require "bundler/setup"
require "turbo_tests"

# When this suite itself runs under `turbo_tests --pool command` (CI's
# command-pool job), RSPEC_EXECUTABLE would also flip every nested run the
# specs start to the command pool; each spec picks its own pool.
ENV.delete("RSPEC_EXECUTABLE")

RSpec.configure do |config|
  # Signals, process groups, `ps`/`pgrep`: not on Windows. The fork pool:
  # MRI on POSIX only (JRuby and TruffleRuby run the spawn pool).
  config.filter_run_excluding(posix: true) if Gem.win_platform?
  config.filter_run_excluding(fork: true) unless TurboTests::Pool.fork_supported?

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect

    c.max_formatted_output_length = 200
  end
end
