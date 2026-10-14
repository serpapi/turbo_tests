# frozen_string_literal: true

require_relative "support/reporter_helpers"

# End-to-end reporter output of the CLI on fixtures/reporter.
RSpec.describe "turbo_tests reporter output", :integration do

  # Runtimes are neither read nor recorded, so scheduling does not depend on
  # earlier runs and fixtures stay clean.
  def turbo_tests(fixture, *args, env: {})
    ReporterHelpers.capture(
      { "TEST_ENV_NUMBER" => nil }.merge(env),
      [RbConfig.ruby, File.join(ReporterHelpers::REPO_ROOT, "bin", "turbo_tests"),
       "--runtime-log", "tmp/never_written_runtime.log", "--no-runtime-log", *args],
      chdir: ReporterHelpers.fixture_path(fixture)
    )
  end

  def plain(text)
    ReporterHelpers.normalize_timing(ReporterHelpers.strip_ansi(text))
  end

  # The persistent pool this platform runs by default (Windows has no fork).
  def pool
    TurboTests::Pool.fork_supported? ? "fork" : "spawn"
  end

  def without_banner(text)
    text.sub(/\A\d+ workers? \(\w+\) for \d+ spec files?\n(?:TEST_ENV_NUMBER: .*\n)?/, "")
  end

  def gem_in_bundle?(name)
    ReporterHelpers.capture({}, [RbConfig.ruby, "-e", "require #{name.inspect}"], chdir: ReporterHelpers::REPO_ROOT)
                   .status.success?
  end

  it "prints the banner with the TEST_ENV_NUMBER convention and no seed for a defined order" do
    result = turbo_tests("defined_order", "-n", "2", "--pool", pool)
    output = plain(result.stdout)

    expect(result.status.exitstatus).to eq(0)
    expect(output).to start_with(%(2 workers (#{pool}) for 2 spec files\nTEST_ENV_NUMBER: "", 2\n))
    expect(output).not_to include("seed")
    expect(output.strip).to end_with("20 examples, 0 failures")
  end

  it "omits the TEST_ENV_NUMBER line for one worker" do
    output = plain(turbo_tests("defined_order", "-n", "1", "--pool", pool).stdout)

    expect(output).to start_with("1 worker (#{pool}) for 2 spec files\n")
    expect(output).not_to include("TEST_ENV_NUMBER")
  end

  %w[random_order/rspec_file random_order/spec_helper].each do |fixture|
    it "prints one shared seed at the end when #{fixture} randomizes" do
      output = plain(turbo_tests(fixture, "-n", "2").stdout)
      seeds = output.scan(/^Randomized with seed (\d+)$/).flatten

      expect(seeds).not_to be_empty
      expect(seeds.uniq.size).to eq(1)
      expect(output.strip).to end_with("20 examples, 0 failures\n\nRandomized with seed #{seeds.last}")
    end
  end

  it "prints a forced seed at the start and at the end" do
    output = plain(turbo_tests("defined_order", "-n", "2", "--seed", "1234").stdout)

    expect(without_banner(output)).to start_with("\nRandomized with seed 1234\n")
    expect(output.scan(/^Randomized with seed \d+$/)).to eq(["Randomized with seed 1234"] * 2)
    expect(output.strip).to end_with("20 examples, 0 failures\n\nRandomized with seed 1234")
  end

  it "prints one merged profile ranked like a serial run" do
    output = plain(turbo_tests("profile", "-n", "2").stdout)
    serial = plain(ReporterHelpers.run_serial("profile").stdout)
    ranking = ->(text) { text.scan(/^  (Profile \w+(?: sleeps [\d.]+)?)$/).flatten }

    expect(output.scan(/^Top \d+ slowest examples .*:$/).size).to eq(1)
    expect(output).to include("\nTop 3 slowest examples (")
    expect(output).to include("\nTop 2 slowest example groups:\n")
    expect(ranking.call(output)).to eq(
      ["Profile second sleeps 0.60", "Profile first sleeps 0.35", "Profile first sleeps 0.20",
       "Profile second", "Profile first"]
    )
    expect(ranking.call(output)).to eq(ranking.call(serial))
  end

  it "keeps each top-level group together in documentation output while workers run concurrently" do
    output = plain(turbo_tests("profile", "-n", "2", "-f", "d").stdout)

    expect(output).to start_with(%(2 workers (#{pool}) for 2 spec files\nTEST_ENV_NUMBER: "", 2\n\nProfile ))
    expect(output).to include("\nProfile first\n  sleeps 0.02\n  sleeps 0.20\n  sleeps 0.35\n")
    expect(output).to include("\nProfile second\n  sleeps 0.05\n  sleeps 0.08\n  sleeps 0.60\n")
  end

  it "prints each deprecation once and one deprecation summary" do
    result = turbo_tests("deprecations", "-n", "2")

    expect(result.status.exitstatus).to eq(0)
    expect(result.stderr.scan("foo is deprecated. Use bar instead. Called from").size).to eq(1)
    expect(result.stderr.scan("Deprecation Warnings:").size).to eq(1)
    expect(plain(result.stdout).scan(/^1 deprecation warning total$/).size).to eq(1)
  end

  it "announces run options and an all-filtered-out run once, like rspec" do
    result = turbo_tests("filtered_out", "-n", "2", "-t", "focus")
    serial = plain(ReporterHelpers.run_serial("filtered_out", "-t", "focus").stdout)
    focus = { focus: true }.inspect

    expect(result.status.exitstatus).to eq(0)
    expect(plain(result.stdout)).to eq(
      %(2 workers (#{pool}) for 2 spec files\nTEST_ENV_NUMBER: "", 2\n) +
      "Run options: include #{focus}\n\nAll examples were filtered out\n\n\n" \
      "Finished in N seconds (files took N seconds to load)\n0 examples, 0 failures\n\n"
    )
    expect(without_banner(plain(result.stdout))).to eq(serial)
  end

  it "says No examples found. once, like rspec" do
    result = turbo_tests("no_examples", "-n", "2")
    serial = plain(ReporterHelpers.run_serial("no_examples").stdout)

    expect(result.status.exitstatus).to eq(0)
    expect(plain(result.stdout)).to eq(
      %(2 workers (#{pool}) for 2 spec files\nTEST_ENV_NUMBER: "", 2\n) +
      "No examples found.\n\n\nFinished in N seconds (files took N seconds to load)\n0 examples, 0 failures\n\n"
    )
    expect(without_banner(plain(result.stdout))).to eq(serial)
  end

  it "writes JUnit XML through RspecJunitFormatter" do
    skip "rspec_junit_formatter is not in the bundle" unless gem_in_bundle?("rspec_junit_formatter")

    xml = File.join(ReporterHelpers::REPO_ROOT, "tmp", "reporter_integration_#{Process.pid}.xml")
    begin
      result = turbo_tests("junit", "-n", "2", "-r", "rspec_junit_formatter", "-f", "RspecJunitFormatter", "-o", xml)

      expect(result.status.exitstatus).to eq(1)
      expect(File.read(xml)).to include('tests="7" skipped="2" failures="4" errors="0"')
      expect(File.read(xml).scan("<testcase ").size).to eq(7)
    ensure
      File.delete(xml) if File.exist?(xml)
    end
  end

  it "feeds Fuubar an accurate total" do
    skip "fuubar is not in the bundle" unless gem_in_bundle?("fuubar")

    output = plain(turbo_tests("fuubar", "-n", "2", "-r", "fuubar", "-f", "Fuubar").stdout)

    expect(output).to match(/^Progress: \|=+\|$/)
    expect(output).to include("5 examples, 1 failure, 1 pending")
  end

  it "renders failures like a serial rspec run, without turbo_tests' worker frames" do
    result = turbo_tests("junit", "-n", "1", "-f", "d")
    serial = plain(ReporterHelpers.run_serial("junit", "--format", "documentation").stdout)

    expect(result.status.exitstatus).to eq(1)
    expect(plain(result.stdout)).not_to include("lib/turbo_tests/")
    expect(without_banner(plain(result.stdout))).to eq(serial)
  end

  it "prints the files of failing workers with --print-failed-group" do
    output = plain(turbo_tests("junit", "-n", "2", "--print-failed-group").stdout)

    expect(output).to match(%r{^Group that failed \(worker \d+\): \S*spec/junit_spec\.rb$})
  end

  it "rejects a formatter name that is not a formatter constant" do
    result = turbo_tests("defined_order", "-f", "Kernel.exit")

    expect(result.status.exitstatus).not_to eq(0)
    expect(result.stderr).to include("Formatter 'Kernel.exit' unknown")
  end
end
