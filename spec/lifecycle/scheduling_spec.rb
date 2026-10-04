require "open3"
require_relative "lifecycle_helper"

RSpec.describe "scheduling, runtime log and run options" do
  let(:dir) { "#{LifecycleHelper::FIXTURES}/suite_hooks" }
  let(:files) { %w[file1 file2 file3 file4 late_hook].map { |name| "#{dir}/#{name}_spec.rb" } }
  let(:runtime_log) { File.join(File.dirname(fixture_log), "runtime.log") }

  def examples_in_order(stdout)
    plain(stdout).scan(/^suite hooks (\d)$|^late suite hook$/).map { |(number)| number || "late" }
  end

  it "records per-file runtimes after the run in parallel_tests' format" do
    result = turbo_tests("-n", "2", "--runtime-log", runtime_log, dir)

    expect(result.exitstatus).to eq(0), result.to_s
    lines = File.read(runtime_log).lines.map(&:chomp)
    expect(lines.map { |line| line.split(":").first }).to eq(files.sort)
    expect(lines).to all(match(/\A[^:]+:\d+\.\d+\z/))
  end

  it "does not record with --no-runtime-log" do
    turbo_tests("-n", "2", "--runtime-log", runtime_log, "--no-runtime-log", dir)

    expect(File.exist?(runtime_log)).to be(false)
  end

  it "runs the slowest recorded file first" do
    File.write(runtime_log, files.map { |file| "#{file}:#{file.include?("file3") ? 9 : 2}\n" }.join)

    result = turbo_tests("-n", "1", "-f", "d", "--runtime-log", runtime_log, "--no-runtime-log", dir)

    expect(result.exitstatus).to eq(0), result.to_s
    expect(examples_in_order(result.stdout).first).to eq("3")
  end

  it "splits into static groups and runs only the selected ones with --only-group" do
    File.write(runtime_log, files.each_with_index.map { |file, index| "#{file}:#{index + 1}\n" }.join)

    result = turbo_tests("-n", "2", "--groups", "2", "--only-group", "2", "-f", "d", "--runtime-log", runtime_log,
      "--no-runtime-log", dir)

    # LPT over 5,4,3,2,1 seconds: group 1 = late_hook(5) file2(2) file1(1), group 2 = file4(4) file3(3)
    expect(result.exitstatus).to eq(0), result.to_s
    expect(examples_in_order(result.stdout).sort).to eq(%w[3 4])
    expect(plain(result.stdout)).to include("2 workers (", "for 2 spec files")
  end

  it "rejects --only-group outside the number of groups" do
    result = turbo_tests("--groups", "2", "--only-group", "3", dir)

    expect(result.exitstatus).to eq(1)
    expect(plain(result.stderr)).to include("--only-group 3 is out of range")
  end

  it "runs one job per worker with --static" do
    result = turbo_tests("-n", "2", "--static", "--pool", "spawn", "--no-runtime-log", dir,
      env: {"TURBO_TESTS_FIXTURE_LOG" => fixture_log})

    expect(result.exitstatus).to eq(0), result.to_s
    expect(fixture_lines.grep(/\Abefore /).size).to eq(2)
  end

  it "prints the pool, the probe result and one line per worker with --verbose" do
    result = turbo_tests("-n", "2", "--pool", "spawn", "--verbose", "--no-runtime-log", dir)
    stderr = plain(result.stderr)

    expect(result.exitstatus).to eq(0), result.to_s
    expect(stderr).to include("turbo_tests: pool=spawn workers=2 scheduler=dynamic")
    expect(stderr).to include(%(TEST_ENV_NUMBER of the first worker probed: ""))
    expect(stderr).to match(/^Process 1: .*TEST_ENV_NUMBER= .*turbo_tests\/worker/)
    expect(stderr).to match(/^Process 2: .*TEST_ENV_NUMBER=2 /)
    expect(plain(result.stdout)).to include(%(TEST_ENV_NUMBER: "", 2))
  end

  it "numbers the first worker 1 with --first-is-1" do
    result = turbo_tests("-n", "2", "--first-is-1", "--no-runtime-log", dir)

    expect(result.exitstatus).to eq(0), result.to_s
    expect(plain(result.stdout)).to include("TEST_ENV_NUMBER: 1, 2")
  end

  it "keeps the 2.x programmatic API (TurboTests::Runner.run with a hash)" do
    script = <<~RUBY
      require "turbo_tests"
      exit TurboTests::Runner.run(
        formatters: [{name: "progress", outputs: ["-"]}],
        tags: [],
        files: ["#{LifecycleHelper::FIXTURES}/lines/other_spec.rb"],
        runtime_log: #{runtime_log.inspect},
        verbose: false,
        fail_fast: nil,
        count: 2,
        seed: nil
      )
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(LifecycleHelper::ROOT, "lib"), "-e", script,
      chdir: LifecycleHelper::ROOT, stdin_data: "")

    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    expect(plain(out)).to include("1 worker (", "1 example, 0 failures")
  end

  it "forwards --profile to the workers" do
    result = turbo_tests("-n", "2", "--profile", "--no-runtime-log", dir)

    expect(result.exitstatus).to eq(0), result.to_s
    expect(plain(result.stdout)).to match(/slowest examples/)
  end
end
