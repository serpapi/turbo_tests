require_relative "lifecycle_helper"

RSpec.describe "path:line selectors (fixtures/lifecycle/lines)" do
  LifecycleHelper::POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "runs only the selected examples of a file and whole other files" do
        result = turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log", "-f", "d",
          "#{LifecycleHelper::FIXTURES}/lines/lines_spec.rb:2:6", "#{LifecycleHelper::FIXTURES}/lines/other_spec.rb")

        expect(result.exitstatus).to eq(0), result.to_s
        expect(plain(result.stdout)).to include("first", "third", "runs whole", "3 examples, 0 failures")
        expect(plain(result.stdout)).not_to include("second must not run")
      end
    end
  end
end
