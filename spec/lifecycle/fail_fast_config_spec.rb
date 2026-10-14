require_relative "lifecycle_helper"

RSpec.describe "config.fail_fast inside the suite (fixtures/lifecycle/fail_fast_config)" do
  LifecycleHelper::PERSISTENT_POOLS.each do |pool|
    it "lets the worker finish after(:suite) with --pool #{pool}" do
      # --fail-fast makes the parent interrupt the busy worker; the suite's own
      # config.fail_fast has already set wants_to_quit by then, which used to
      # turn that first INT into exit!(1) and skip after(:suite).
      result = turbo_tests("--pool", pool, "-n", "1", "--no-runtime-log", "--fail-fast",
        "#{LifecycleHelper::FIXTURES}/fail_fast_config/failing_spec.rb",
        env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})

      expect(result.exitstatus).to eq(1), result.to_s
      expect(plain(result.stdout)).to include("1 example, 1 failure")
      expect(plain(result.stdout)).not_to include("worker error")
      expect(fixture_lines.grep(/\Aafter_suite /).size).to eq(1)
    end
  end
end
