RSpec.configure do |config|
  config.before(:suite) { raise "before(:suite) failed" if ENV["TURBO_TESTS_FIXTURE_FAIL"] == "before" }
  config.after(:suite) { raise "after(:suite) failed" if ENV["TURBO_TESTS_FIXTURE_FAIL"] == "after" }
end
