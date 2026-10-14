require_relative "spec_helper"

RSpec.describe "suite hooks 3" do
  it("runs") { turbo_tests_fixture_log("example 3 #{Process.pid}") }
end
