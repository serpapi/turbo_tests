require_relative "lifecycle_helper"

RSpec.describe "suite hooks (fixtures/lifecycle/suite_hooks)" do
  def run(pool)
    turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log", "#{LifecycleHelper::FIXTURES}/suite_hooks",
      env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})
  end

  def pids_of(kind)
    fixture_lines.grep(/\A#{kind} /).map { |line| line.split.last }
  end

  %w[fork spawn].each do |pool|
    context "with --pool #{pool}" do
      it "runs before(:suite) and after(:suite) once per worker, including hooks registered by later files" do
        result = run(pool)
        example_pids = fixture_lines.grep(/\Aexample /).map { |line| line.split.last }.uniq

        expect(result.exitstatus).to eq(0), result.to_s
        expect(plain(result.stdout)).to include("5 examples, 0 failures")
        expect(pids_of("before").sort).to eq(example_pids.sort)
        expect(pids_of("after").sort).to eq(example_pids.sort)
        late_worker = fixture_lines.grep(/\Aexample late /).first.split.last
        expect(pids_of("late")).to eq([late_worker])
      end
    end
  end

  context "with --pool command" do
    it "runs them once per rspec process" do
      result = run("command")

      expect(result.exitstatus).to eq(0), result.to_s
      expect(pids_of("before").size).to eq(2)
      expect(pids_of("after").sort).to eq(pids_of("before").sort)
    end
  end
end

RSpec.describe "suite hooks that raise (fixtures/lifecycle/suite_hook_errors)" do
  def run(pool, failing)
    turbo_tests("--pool", pool, "-n", "1", "--no-runtime-log", "#{LifecycleHelper::FIXTURES}/suite_hook_errors",
      env: {"TURBO_TESTS_FIXTURE_FAIL" => failing})
  end

  %w[fork spawn command].each do |pool|
    context "with --pool #{pool}" do
      it "skips every job of the worker after a before(:suite) failure and fails the run" do
        result = run(pool, "before")
        stdout = plain(result.stdout)

        expect(result.exitstatus).to eq(1), result.to_s
        expect(stdout).to include("An error occurred in a `before(:suite)` hook", "before(:suite) failed")
        expect(stdout).to match(/0 examples, 0 failures, 1 error occurred outside of examples/)
      end

      it "reports an after(:suite) failure and fails the run" do
        result = run(pool, "after")
        stdout = plain(result.stdout)

        expect(result.exitstatus).to eq(1), result.to_s
        expect(stdout).to include("An error occurred in an `after(:suite)` hook", "after(:suite) failed")
        expect(stdout).to match(/2 examples, 0 failures, 1 error occurred outside of examples/)
      end
    end
  end
end
