require_relative "helper"

RSpec.describe "slow" do
  it "keeps running and leaves a grandchild behind" do
    turbo_tests_fixture_log("worker #{Process.pid}")
    pid = Process.spawn("sleep", "300", out: File::NULL)
    Process.detach(pid)
    turbo_tests_fixture_log("grandchild #{pid}")
    sleep 3
  end

  it("is skipped after fail-fast") { turbo_tests_fixture_log("second example ran") }
end
