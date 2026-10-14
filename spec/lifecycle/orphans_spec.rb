require_relative "lifecycle_helper"

RSpec.describe "fail-fast leaves no process behind (fixtures/lifecycle/orphans)", :posix do
  LifecycleHelper::POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "stops dispatching, interrupts busy workers and cleans up their process groups" do
        result = turbo_tests("--pool", pool, "-n", "4", "--fail-fast", "--exit-timeout", "20", "--no-runtime-log",
          "#{LifecycleHelper::FIXTURES}/orphans", env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})
        pids = fixture_lines.map { |line| line[/\A(?:worker|grandchild) (\d+)\z/, 1] }.compact.map(&:to_i)

        expect(result.exitstatus).to eq(1), result.to_s
        expect(result.wall).to be < 20
        expect(fixture_lines.grep(/\Agrandchild /)).not_to be_empty
        expect(fixture_lines).not_to include("second example ran")
        expect(pids).not_to be_empty
        expect(eventually_dead?(pids)).to be(true), "still alive: #{pids.select { |pid| alive?(pid) }}"
      end
    end
  end
end
