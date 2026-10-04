require_relative "helper"

RSpec.describe "failing 1" do
  it "fails after the slow file started" do
    turbo_tests_fixture_log("worker #{Process.pid}")
    wait_for_grandchild
    expect(1).to eq(0)
  end
end
