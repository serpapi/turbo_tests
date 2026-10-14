require_relative "lifecycle_helper"

RSpec.describe "spec_helper raising while it is preloaded (fixtures/lifecycle/preload_error)" do
  let(:project) { File.join(LifecycleHelper::ROOT, LifecycleHelper::FIXTURES, "preload_error") }

  LifecycleHelper::PERSISTENT_POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "reports the error once per booting process and runs nothing" do
        result = turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log", chdir: project)
        stdout = plain(result.stdout)

        expect(result.exitstatus).to eq(1), result.to_s
        expect(result.wall).to be < 20
        expect(stdout).to include("An error occurred while loading spec_helper", "spec_helper is broken")
        expect(stdout).to match(/0 examples, 0 failures, \d errors? occurred outside of examples/)
      end
    end
  end
end
