RSpec.configure do |config|
  config.example_status_persistence_file_path = ENV.fetch("TURBO_TESTS_FIXTURE_STATUS", "tmp/only_failures_status.txt")
end
