require_relative "lifecycle_helper"

RSpec.describe "a grandchild holding a worker's pipes (fixtures/lifecycle/pipe_holder_spec.rb)", :posix do
  LifecycleHelper::POOLS.each do |pool|
    context "with --pool #{pool}" do
      it "does not keep the run waiting for EOF and is cleaned up with the worker's process group" do
        result = turbo_tests("--pool", pool, "--no-runtime-log", "#{LifecycleHelper::FIXTURES}/pipe_holder_spec.rb",
          env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})
        grandchild = fixture_lines.grep(/\Agrandchild /).first.to_s.split.last.to_i

        expect(result.exitstatus).to eq(0), result.to_s
        expect(result.wall).to be < 10
        expect(result.pipes_closed).to be(true)
        expect(grandchild).to be > 0
        expect(eventually_dead?([grandchild])).to be(true)
      end
    end
  end
end
