def turbo_tests_fixture_log(line)
  path = ENV["TURBO_TESTS_FIXTURE_LOG"]
  File.open(path, "a") { |f| f.puts(line) } if path
end

RSpec.configure do |config|
  config.before(:suite) { turbo_tests_fixture_log("before #{Process.pid}") }
  config.after(:suite) { turbo_tests_fixture_log("after #{Process.pid}") }
end
