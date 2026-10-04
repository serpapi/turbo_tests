require_relative "lifecycle_helper"

RSpec.describe "a process forked during preload keeps the control pipe (fixtures/lifecycle/forked_pipe_holder)" do
  it "does not keep the run waiting with --pool fork" do
    pids = []
    result = turbo_tests("--pool", "fork", "-n", "1", "--no-runtime-log",
      "--preload", "#{LifecycleHelper::FIXTURES}/forked_pipe_holder/preload.rb",
      "#{LifecycleHelper::FIXTURES}/forked_pipe_holder/a_spec.rb",
      env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})
    pids = fixture_lines.map { |line| line[/\Agrandchild (\d+)\z/, 1] }.compact.map(&:to_i)

    expect(pids.size).to eq(1), result.to_s
    expect(result.exitstatus).to eq(0), result.to_s
    expect(result.wall).to be < 15
    expect(plain(result.stdout)).to include("1 example, 0 failures")
  ensure
    pids.each do |pid|
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
