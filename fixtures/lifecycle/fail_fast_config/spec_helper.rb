# The suite itself stops at the first failure; turbo_tests must still let the
# worker finish cleanly (after(:suite), at_exit) instead of force-killing it.
RSpec.configure do |config|
  config.fail_fast = true
  config.after(:suite) do
    File.open(ENV.fetch("TURBO_TESTS_FIXTURE_LOG"), "a") { |f| f.puts "after_suite #{Process.pid}" }
  end
end
