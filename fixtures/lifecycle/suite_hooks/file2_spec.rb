require_relative "spec_helper"

RSpec.describe "suite hooks 2" do
  it("runs") { turbo_tests_fixture_log("example 2 #{Process.pid}") }
end
