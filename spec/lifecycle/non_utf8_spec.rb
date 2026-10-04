require_relative "lifecycle_helper"

RSpec.describe "output that is not valid UTF-8 (fixtures/lifecycle/non_utf8_spec.rb)" do
  LifecycleHelper::POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "passes through byte for byte" do
        result = turbo_tests("--pool", pool, "--no-runtime-log", "-f", "d", "#{LifecycleHelper::FIXTURES}/non_utf8_spec.rb",
          env: {"LANG" => "C", "LC_ALL" => "C"})

        expect(result.exitstatus).to eq(0), result.to_s
        expect(result.stdout).to include("raw bytes: \xFF\xFE\n".b)
        expect(result.stdout).to include("accent: é\n".b)
        expect(plain(result.stdout)).to include("prints raw bytes and accents (é)", "1 example, 0 failures")
      end
    end
  end
end
