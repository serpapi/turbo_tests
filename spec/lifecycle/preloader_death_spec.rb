require_relative "lifecycle_helper"

RSpec.describe "the fork preloader dying after its first fork (fixtures/lifecycle/preloader_death)" do
  it "reports the workers that never ran as crashed, kills the orphan and fails the run" do
    dir = "#{LifecycleHelper::FIXTURES}/preloader_death"
    result = turbo_tests("--pool", "fork", "-n", "3", "--no-runtime-log", "--preload", "#{dir}/preload.rb", dir)
    stderr = plain(result.stderr)

    expect(result.exitstatus).to eq(1), result.to_s
    expect(result.wall).to be < 20
    expect(stderr).to include("the preloader exited")
    expect(stderr).to match(/Worker 2 exited with status unknown \(never forked: the preloader exited with status SIGKILL\) before finishing/)
    expect(stderr).to match(/Worker 3 exited with status unknown \(never forked: the preloader exited with status SIGKILL\) before finishing/)
    # Worker 1 was forked but never reported: depending on timing it got a job before the parent noticed.
    expect(stderr).to match(/Worker 1 exited with status .* before finishing/)
    expect(stderr).not_to include("failed after fork")
  end
end
