require_relative "lifecycle_helper"

RSpec.describe "Ctrl-C (SIGINT to the parent)" do
  %w[fork spawn].each do |pool|
    context "with --pool #{pool}" do
      it "stops after the current examples, prints the summary and leaves no worker behind" do
        log = fixture_log
        reader = Thread.new do
          turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log", "--exit-timeout", "20",
            "#{LifecycleHelper::FIXTURES}/orphans/slow_spec.rb", env: {"TURBO_TESTS_FIXTURE_LOG" => log})
        end
        deadline = monotonic + 30
        sleep 0.05 until File.exist?(log) && File.read(log).include?("grandchild") || monotonic > deadline
        parent = IO.popen(["pgrep", "-f", "#{LifecycleHelper::BIN}.*slow_spec"], &:read).split.map(&:to_i).min
        expect(parent).not_to be_nil
        Process.kill("INT", parent)
        result = reader.value
        pids = fixture_lines.map { |line| line[/\A(?:worker|grandchild) (\d+)\z/, 1] }.compact.map(&:to_i)

        # Interrupted runs are incomplete: 130 (128 + SIGINT) tells CI wrappers apart from test failures.
        expect(result.exitstatus).to eq(130), result.to_s
        expect(result.wall).to be < 20
        expect(plain(result.stdout)).to match(/1 example, 0 failures/)
        expect(fixture_lines).not_to include("second example ran")
        expect(eventually_dead?(pids)).to be(true)
      end
    end
  end
end
