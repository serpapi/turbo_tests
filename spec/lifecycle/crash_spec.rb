require_relative "lifecycle_helper"

RSpec.describe "a worker killed in the middle of a job (fixtures/lifecycle/crash_spec.rb)" do
  LifecycleHelper::POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "is reported with its status and files and fails the run" do
        result = turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log",
          "#{LifecycleHelper::FIXTURES}/crash_spec.rb", "#{LifecycleHelper::FIXTURES}/lines/other_spec.rb")

        expect(result.exitstatus).to eq(1), result.to_s
        expect(plain(result.stderr)).to match(%r{Worker \d exited with status SIGKILL before finishing\. Files: fixtures/lifecycle/crash_spec\.rb})
        expect(plain(result.stdout)).to include("runs whole").or include("1 example")
        expect(result.wall).to be < 30
      end
    end
  end
end
