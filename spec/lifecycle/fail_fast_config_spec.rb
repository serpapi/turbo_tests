require_relative "lifecycle_helper"

RSpec.describe "config.fail_fast inside the suite (fixtures/lifecycle/fail_fast_config)" do
  %w[fork spawn].each do |pool|
    it "lets the worker finish after(:suite) with --pool #{pool}" do
      result = turbo_tests("--pool", pool, "-n", "1", "--no-runtime-log", "#{LifecycleHelper::FIXTURES}/fail_fast_config/failing_spec.rb",
        env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})

      expect(result.exitstatus).to eq(1), result.to_s
      expect(plain(result.stdout)).to include("1 example, 1 failure")
      expect(plain(result.stdout)).not_to include("worker error")
      expect(fixture_lines.grep(/\Aafter_suite /).size).to eq(1)
    end
  end
end
