require_relative "spec_helper"

RSpec.describe "suite hooks 1" do
  it("runs") { turbo_tests_fixture_log("example 1 #{Process.pid}") }
end
