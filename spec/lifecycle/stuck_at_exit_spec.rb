require_relative "lifecycle_helper"

RSpec.describe "a worker that never exits (fixtures/lifecycle/stuck_at_exit_spec.rb)" do
  LifecycleHelper::POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "is killed after --exit-timeout, named with its file and diagnosed, and fails the run" do
        result = turbo_tests("--pool", pool, "--exit-timeout", "3", "--no-runtime-log",
          "#{LifecycleHelper::FIXTURES}/stuck_at_exit_spec.rb")
        stderr = plain(result.stderr)

        expect(result.exitstatus).to eq(1), result.to_s
        expect(result.wall).to be < 15
        expect(plain(result.stdout)).to include("1 example, 0 failures")
        expect(stderr).to match(%r{Worker 1 did not exit 3s after finishing RSpec; killed\. Files: fixtures/lifecycle/stuck_at_exit_spec\.rb})
        expect(stderr).to include("still alive 1.5s after finishing RSpec")
        expect(stderr).to match(/stuck_at_exit_spec\.rb:3 sleep>/)
        expect(stderr).to include("ensure block")
        expect(stderr).to match(/stuck_at_exit_spec\.rb:5:in .*sleep/)
      end
    end
  end
end
