require_relative "spec_helper"

RSpec.describe "suite hooks 4" do
  it("runs") { turbo_tests_fixture_log("example 4 #{Process.pid}") }
end
