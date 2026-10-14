require_relative "lifecycle_helper"

RSpec.describe "a slow application boot (fixtures/lifecycle/slow_boot)" do
  let(:dir) { "#{LifecycleHelper::FIXTURES}/slow_boot" }

  def boots
    fixture_lines.grep(/\Aboot /).size
  end

  it "boots once in the fork preloader when the boot is preloaded", :posix do
    result = turbo_tests("--pool", "fork", "-n", "4", "--no-runtime-log", "--preload", "#{dir}/spec_helper.rb", dir,
      env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})

    expect(result.exitstatus).to eq(0), result.to_s
    expect(plain(result.stdout)).to include("4 workers (fork) for 4 spec files", "4 examples, 0 failures")
    expect(boots).to eq(1)
  end

  it "boots once per spawned worker" do
    result = turbo_tests("--pool", "spawn", "-n", "2", "--no-runtime-log", dir, env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})

    expect(result.exitstatus).to eq(0), result.to_s
    expect(plain(result.stdout)).to include("4 examples, 0 failures")
    expect(boots).to eq(2)
  end

  it "boots once per rspec process with --pool command" do
    result = turbo_tests("--pool", "command", "-n", "2", "--no-runtime-log", dir, env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})

    expect(result.exitstatus).to eq(0), result.to_s
    expect(plain(result.stdout)).to include("2 workers (command) for 4 spec files", "4 examples, 0 failures")
    expect(boots).to eq(2)
  end
end
