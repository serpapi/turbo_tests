require_relative "spec_helper"

RSpec.configure do |config|
  config.before(:suite) { turbo_tests_fixture_log("late #{Process.pid}") }
end

RSpec.describe "late suite hook" do
  it("runs") { turbo_tests_fixture_log("example late #{Process.pid}") }
end
