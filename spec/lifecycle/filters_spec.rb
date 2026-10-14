require_relative "lifecycle_helper"

RSpec.describe "filters configured in spec_helper (fixtures/lifecycle/filters)" do
  LifecycleHelper::POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "still apply when a worker runs its second job" do
        result = turbo_tests("--pool", pool, "-n", "1", "--no-runtime-log", "#{LifecycleHelper::FIXTURES}/filters")

        expect(result.exitstatus).to eq(0), result.to_s
        expect(plain(result.stdout)).to include("2 examples, 0 failures")
        expect(plain(result.output)).not_to include("excluded example ran")
      end
    end
  end
end
