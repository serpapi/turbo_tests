require_relative "lifecycle_helper"

RSpec.describe "GC between jobs (fixtures/lifecycle/gc_between_jobs)" do
  LifecycleHelper::PERSISTENT_POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "keeps the rows channel alive across jobs of one worker" do
        result = turbo_tests("--pool", pool, "-n", "1", "--no-runtime-log", "#{LifecycleHelper::FIXTURES}/gc_between_jobs")

        expect(result.exitstatus).to eq(0), result.to_s
        expect(plain(result.stdout)).to include("1 worker (#{pool}) for 3 spec files", "6 examples, 0 failures")
      end
    end
  end
end
