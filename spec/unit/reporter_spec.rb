# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../reporter/support/reporter_helpers"

RSpec.describe TurboTests::Reporter do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:format) { "progress" }
  let(:seed) { 1234 }
  let(:seed_used) { false }

  subject(:reporter) do
    described_class.from_config(
      [{ name: format, outputs: ["-"] }], RSpec::Core::Time.now, seed, seed_used, out: out, err: err
    )
  end

  def example_row(type, description, group: "Group", file: "./spec/group_spec.rb", index: 1, line: index + 1,
                  run_time: 0.01, worker: nil, skipped: false, pending_message: nil)
    status = { "example_passed" => "passed", "example_failed" => "failed", "example_pending" => "pending" }.fetch(type)
    exception =
      if type == "example_failed"
        { class_name: "RuntimeError", message: "boom", backtrace: ["#{file}:#{line}:in `block (2 levels)'"], cause: nil }
      end
    row = {
      type: type,
      example: {
        id: "#{file}[1:#{index}]",
        description: description,
        full_description: "#{group} #{description}",
        location: "#{file}:#{line}",
        location_rerun_argument: "#{file}:#{line}",
        file_path: file,
        line_number: line,
        run_time: run_time,
        execution_result: {
          status: status, "example_skipped?": skipped, pending_message: pending_message, "pending_fixed?": false,
          exception: exception, pending_exception: nil
        },
        metadata: { shared_group_inclusion_backtrace: [], extra_failure_lines: nil },
        top_level_group: { description: group, location: "#{file}:1", file_path: file, line_number: 1 }
      }
    }
    row[:worker] = worker if worker
    row
  end

  def load_summary(count, load_time = 0.1, worker: nil)
    { type: "load_summary", summary: { count: count, load_time: load_time }, worker: worker }
  end

  def run_rows(rows, run: 0)
    reporter.report(run) { |r| rows.each { |row| r.handle(row) } }
    text
  end

  # This suite runs with --color; RSpec's formatters colour in-process output.
  def text
    ReporterHelpers.strip_ansi(out.string)
  end

  describe "banner" do
    it "prints workers, pool and spec files, then each worker's TEST_ENV_NUMBER" do
      run_rows([], run: { workers: 3, pool: :fork, files: 12, test_env_numbers: ["", "2", "3"] })

      expect(text).to start_with(%(3 workers (fork) for 12 spec files\nTEST_ENV_NUMBER: "", 2, 3\n))
    end

    it "shows the first-is-1 convention and counts file lists" do
      run_rows([], run: { workers: 2, pool: "spawn", files: %w[a_spec.rb b_spec.rb c_spec.rb], test_env_numbers: %w[1 2] })

      expect(text).to start_with("2 workers (spawn) for 3 spec files\nTEST_ENV_NUMBER: 1, 2\n")
    end

    it "omits TEST_ENV_NUMBER for a single worker" do
      run_rows([], run: { workers: 1, pool: "fork", files: ["spec/a_spec.rb"], test_env_numbers: [""] })

      expect(text.lines.first).to eq("1 worker (fork) for 1 spec file\n")
      expect(text).not_to include("TEST_ENV_NUMBER")
    end

    it "keeps the v2 banner for an array of file groups" do
      run_rows([], run: [%w[a_spec.rb b_spec.rb], %w[c_spec.rb]])

      expect(text.lines.first).to eq("2 processes for 3 specs, ~ 2 specs per process\n")
    end

    it "prints no banner for a bare example count" do
      run_rows([example_row("example_passed", "works")], run: 1)

      expect(text).to start_with(".")
    end
  end

  describe "seed" do
    def seed_row(used, value = seed)
      { type: "seed", seed: value, seed_used: used }
    end

    def seed_lines
      text.scan(/^Randomized with seed \d+$/)
    end

    context "when forced with --seed" do
      let(:seed_used) { true }

      it "prints it at the start and at the end when workers used it" do
        run_rows([seed_row(true), example_row("example_passed", "works"), seed_row(true)])

        expect(seed_lines).to eq(["Randomized with seed 1234"] * 2)
        expect(text).to start_with("\nRandomized with seed 1234\n.")
      end

      it "prints it only at the start when no worker used it (files failed to load)" do
        run_rows([seed_row(false), load_summary(0), seed_row(false)])

        expect(seed_lines).to eq(["Randomized with seed 1234"])
        expect(text).to start_with("\nRandomized with seed 1234\n")
      end
    end

    context "when not forced" do
      it "prints the seed workers reported at the end when they used it" do
        run_rows([seed_row(true, 999), example_row("example_passed", "works"), seed_row(true, 999)])

        expect(seed_lines).to eq(["Randomized with seed 999"])
        expect(text).to end_with("1 example, 0 failures\n\nRandomized with seed 999\n\n")
      end

      it "prints it at the start too when the config row says the order is random" do
        reporter.config(type: "config", order: "random", seed: 1234, profile_examples: nil)
        run_rows([seed_row(true), example_row("example_passed", "works"), seed_row(true)])

        expect(seed_lines).to eq(["Randomized with seed 1234"] * 2)
      end

      it "never prints it when no worker used it" do
        run_rows([seed_row(false), example_row("example_passed", "works"), seed_row(false)])

        expect(text).not_to include("seed")
      end
    end

    context "without a seed value" do
      let(:seed) { nil }
      let(:seed_used) { true }

      it "prints nothing" do
        run_rows([{ type: "seed", seed: nil, seed_used: true }, example_row("example_passed", "works")])

        expect(text).not_to include("seed")
      end
    end
  end

  describe "profile" do
    let(:timings) do
      {
        1 => { "./spec/one_spec.rb" => ["One", [0.05, 0.40, 0.25, 0.10]] },
        2 => { "./spec/two_spec.rb" => ["Two", [0.30, 0.35, 0.01]], "./spec/three_spec.rb" => ["Three", [0.21]] }
      }
    end

    let(:example_rows) do
      timings.flat_map do |worker, files|
        files.flat_map do |file, (group, run_times)|
          run_times.each_with_index.map do |run_time, index|
            example_row("example_passed", "takes #{run_time}", group: group, file: file, index: index + 1,
                                                               run_time: run_time, worker: worker)
          end
        end
      end
    end

    def group_stats(rows)
      rows.group_by { |row| row[:example][:top_level_group] }.map do |group, group_rows|
        { location: group[:location], description: group[:description],
          total_time: group_rows.sum { |row| row[:example][:run_time] }, count: group_rows.size }
      end
    end

    # What JsonRowsFormatter sends for one worker: its own top 3.
    def profile_row(worker, duration)
      rows = example_rows.select { |row| row[:worker] == worker }
      examples = rows.map { |row| row[:example] }.sort_by { |example| -example[:run_time] }.first(3)
      {
        type: "dump_profile",
        slowest_examples: examples.map { |example| example.select { |key, _| %i[id description full_description location run_time].include?(key) } },
        slowest_groups: group_stats(rows).sort_by { |group| -group[:total_time] / group[:count] }.first(3),
        duration: duration,
        number_of_examples: 3,
        worker: worker
      }
    end

    # RSpec's own rendering of a single process that ran every example.
    def serial_profile
      examples = example_rows.map { |row| TurboTests::FakeExample.from_obj(row[:example]) }
      groups = {}
      group_stats(example_rows).each do |stats|
        group = TurboTests::FakeExampleGroup.new(description: stats[:description], location: stats[:location])
        groups[group] = stats.select { |key, _| %i[description total_time count].include?(key) }
      end
      notification = RSpec::Core::Notifications::ProfileNotification.new(3.0, examples, 3, groups)
      output = StringIO.new
      RSpec::Core::Formatters::ProfileFormatter.new(output).dump_profile(notification)
      output.string
    end

    let(:profile_rows) { [profile_row(1, 1.0), profile_row(2, 2.0)] }

    it "merges per-worker top N lists into exactly what one RSpec process prints" do
      reporter.config(type: "config", profile_examples: 3)
      run_rows(example_rows + profile_rows)

      expect(out.string).to include(serial_profile)
      expect(text.scan("slowest examples").size).to eq(1)
      expect(text.scan("slowest example groups").size).to eq(1)
      expect(ReporterHelpers.strip_ansi(serial_profile)).to include("Top 3 slowest examples (1.05 seconds, 35.0% of total time):")
      expect(ReporterHelpers.strip_ansi(serial_profile).scan(/^  (\w+)$/).flatten).to eq(%w[Two Three One])
    end

    it "is enabled by profile rows or --profile and sized by the configured N" do
      reporter.profile_examples = 2
      run_rows(example_rows + profile_rows)

      expect(ReporterHelpers.strip_ansi(out.string)).to include("Top 2 slowest examples (0.75 seconds, 25.0% of total time):")
    end

    it "prints nothing when profiling is off" do
      run_rows(example_rows)

      expect(text).not_to include("slowest")
    end

    it "leaves out the groups section when the run had a single top-level group, like RSpec" do
      rows = example_rows.select { |row| row[:worker] == 1 }
      run_rows(rows + [profile_row(1, 1.0)])

      expect(text).to include("Top 3 slowest examples")
      expect(text).not_to include("slowest example groups")
    end

    it "is muted when --fail-fast stopped the run, like RSpec" do
      reporter.config(type: "config", profile_examples: 3, fail_fast: 1)
      run_rows(example_rows + [example_row("example_failed", "fails", index: 9)] + profile_rows)

      expect(text).not_to include("slowest")
    end

    context "with a formatter that implements dump_profile" do
      let(:format) { "json" }

      it "hands it the merged profile instead of printing RSpec's profile section" do
        reporter.config(type: "config", profile_examples: 3)
        run_rows(example_rows + profile_rows)
        profile = JSON.parse(out.string).fetch("profile")

        expect(profile["examples"].map { |example| example["description"] }).to eq(["takes 0.4", "takes 0.35", "takes 0.3"])
        expect(profile["groups"].map { |group| group["description"] }).to eq(%w[Two Three One])
        expect(profile["total"]).to eq(3.0)
        expect(text).not_to include("Top 3")
      end
    end

    it "merges two real workers into the ranking of a serial run" do
      first = ReporterHelpers.run_worker("profile", "spec/first_spec.rb")
      second = ReporterHelpers.run_worker("profile", "spec/second_spec.rb")
      serial = ReporterHelpers.strip_ansi(ReporterHelpers.run_serial("profile").stdout)
      merged = ReporterHelpers.strip_ansi(ReporterHelpers.replay("profile", first.rows + second.rows, "progress").stdout)
      ranking = ->(text) { text.scan(/^  (Profile \w+(?: sleeps [\d.]+)?)$/).flatten }

      expect(merged.scan(/^Top \d+ slowest examples/)).to eq(["Top 3 slowest examples"])
      expect(merged.scan(/^Top \d+ slowest example groups:$/)).to eq(["Top 2 slowest example groups:"])
      expect(ranking.call(merged)).to eq(
        ["Profile second sleeps 0.90", "Profile first sleeps 0.35", "Profile first sleeps 0.20",
         "Profile second", "Profile first"]
      )
      expect(ranking.call(merged)).to eq(ranking.call(serial))
    end
  end

  describe "deprecations" do
    let(:row) do
      { type: "deprecation", message: nil, deprecated: "foo", replacement: "bar",
        call_site: "/project/spec/spec_helper.rb:3:in `call_deprecated_helper'" }
    end
    let(:other) { row.merge(call_site: "/project/spec/other_spec.rb:9:in `block (2 levels)'") }

    it "replays each distinct deprecation once through one DeprecationFormatter with one summary" do
      run_rows([row, { type: "deprecation_summary" }, row, other, { type: "deprecation_summary" }, row])
      expected_err = StringIO.new
      expected_out = StringIO.new
      formatter = RSpec::Core::Formatters::DeprecationFormatter.new(expected_err, expected_out)
      [row, other].each do |data|
        formatter.deprecation(RSpec::Core::Notifications::DeprecationNotification.from_hash(data))
      end
      formatter.deprecation_summary(nil)

      expect(err.string).to eq(expected_err.string)
      expect(err.string.scan("foo is deprecated. Use bar instead.").size).to eq(2)
      expect(text.scan("deprecation warning").size).to eq(1)
      expect(text).to include("\n2 deprecation warnings total\n")
    end

    it "prints nothing when there were none" do
      run_rows([{ type: "deprecation_summary" }, example_row("example_passed", "works")])

      expect(err.string).to eq("")
      expect(text).not_to include("deprecation")
    end
  end

  describe "filter announcements" do
    let(:focus) { "Run options: include #{{ focus: true }.inspect}" }

    def zero_example_rows(message)
      [1, 2].flat_map do |worker|
        [
          { type: "message", message: focus, worker: worker },
          load_summary(0, worker: worker),
          { type: "message", message: message, worker: worker }
        ]
      end
    end

    it "announces the run options and an all-filtered-out run once" do
      reporter.run_options = ["focus"]
      run_rows(zero_example_rows("\nAll examples were filtered out"))

      expect(text).to start_with("#{focus}\n\nAll examples were filtered out\n")
      expect(text.scan("Run options").size).to eq(1)
      expect(text.scan("All examples were filtered out").size).to eq(1)
      expect(text).to include("0 examples, 0 failures")
    end

    it "says the run was filtered out when workers were silenced" do
      reporter.run_options = ["focus"]
      run_rows([load_summary(0), load_summary(0)])

      expect(text).to start_with("#{focus}\n\nAll examples were filtered out\n")
    end

    it "prints No examples found. once without filters" do
      run_rows([load_summary(0), { type: "message", message: "No examples found." }] * 2)

      expect(text.scan("No examples found.").size).to eq(1)
    end

    it "stays quiet when another worker ran examples" do
      reporter.run_options = ["focus"]
      run_rows(zero_example_rows("\nAll examples were filtered out") +
               [load_summary(1, worker: 3), example_row("example_passed", "focused", worker: 3)])

      expect(text).not_to include("All examples were filtered out")
      expect(text.scan("Run options").size).to eq(1)
    end

    it "lists inclusions and exclusions like RSpec and then says nothing about zero examples" do
      reporter.run_options = ["focus", "~slow"]
      run_rows([load_summary(0)])

      expect(text).to start_with(
        "Run options:\n  include #{{ focus: true }.inspect}\n  exclude #{{ slow: true }.inspect}\n"
      )
      expect(text).not_to include("filtered out")
      expect(text).not_to include("No examples found.")
    end

    it "honours silence_filter_announcements from the config row" do
      reporter.config(type: "config", silence_filter_announcements: true)
      reporter.run_options = ["focus"]
      run_rows(zero_example_rows("\nAll examples were filtered out"))

      expect(text).not_to include("Run options")
      expect(text).not_to include("filtered out")
    end
  end

  describe "documentation output with concurrent workers" do
    let(:format) { "documentation" }

    def group_row(type, description, worker, line: 1)
      { type: type, group: { description: description, location: "./spec/#{description}_spec.rb:#{line}",
                             file_path: "./spec/#{description}_spec.rb", line_number: line }, worker: worker }
    end

    def passed(description, group, worker)
      example_row("example_passed", description, group: group, file: "./spec/#{group}_spec.rb", worker: worker)
    end

    it "shows each worker's top-level group as a whole while the other worker waits" do
      run_rows(
        [
          group_row("group_started", "alpha", 1), passed("a1", "alpha", 1),
          group_row("group_started", "beta", 2), passed("b1", "beta", 2),
          group_row("group_started", "inner", 1, line: 3), passed("a2", "alpha", 1),
          group_row("group_finished", "inner", 1, line: 3),
          { type: "message", message: "beta says hi", worker: 2 },
          group_row("group_finished", "alpha", 1),
          passed("b2", "beta", 2), group_row("group_finished", "beta", 2)
        ]
      )

      expect(text).to start_with("\nalpha\n  a1\n  inner\n    a2\n\nbeta\n  b1\n  beta says hi\n  b2\n\nFinished in ")
    end

    it "streams the next worker once the first one finished its group" do
      reporter.report(0) do |r|
        r.handle(group_row("group_started", "alpha", 1))
        r.handle(group_row("group_started", "beta", 2))
        r.handle(passed("b1", "beta", 2))
        expect(text).to eq("\nalpha\n")
        r.handle(group_row("group_finished", "alpha", 1))
        expect(text).to eq("\nalpha\n\nbeta\n  b1\n")
        r.handle(passed("b2", "beta", 2))
        expect(text).to end_with("  b1\n  b2\n")
      end
    end

    it "still returns :failure and fails the run when a failed example has to wait" do
      reporter.report(0) do |r|
        r.handle(group_row("group_started", "alpha", 1))
        expect(r.handle(example_row("example_failed", "b1", group: "beta", worker: 2))).to eq(:failure)
        expect(r).not_to be_success
      end

      expect(reporter.failed_examples.map(&:description)).to eq(["b1"])
    end

    it "closes the groups of a crashed worker and lets the others through" do
      reporter.report(0) do |r|
        r.handle(group_row("group_started", "alpha", 1))
        r.handle(passed("a1", "alpha", 1))
        r.handle(group_row("group_started", "beta", 2))
        r.handle(passed("b1", "beta", 2))
        r.worker_crashed(1, ["spec/alpha_spec.rb"], "SIGKILL")
        expect(text).to eq("\nalpha\n  a1\n\nbeta\n  b1\n")
      end
    end

    it "shows rows still waiting when the run ends" do
      run_rows([group_row("group_started", "alpha", 1), group_row("group_started", "beta", 2), passed("b1", "beta", 2)])

      expect(text).to start_with("\nalpha\n\nbeta\n  b1\n")
    end

    context "with the progress formatter" do
      let(:format) { "progress" }

      it "shows rows as they arrive" do
        reporter.report(0) do |r|
          r.handle(group_row("group_started", "alpha", 1))
          r.handle(group_row("group_started", "beta", 2))
          r.handle(passed("b1", "beta", 2))
          expect(text).to eq(".")
        end
      end
    end
  end

  describe "rows from real workers" do
    def normalize(text)
      ReporterHelpers.normalize_timing(ReporterHelpers.strip_ansi(text))
    end

    def two_workers(fixture, *args)
      %w[spec/a_spec.rb spec/b_spec.rb].flat_map { |file| ReporterHelpers.run_worker(fixture, *args, file).rows }
    end

    it "prints what rspec prints when every worker filtered out all its examples" do
      replayed = ReporterHelpers.replay("filtered_out", two_workers("filtered_out", "-t", "focus"), "progress")
      serial = ReporterHelpers.run_serial("filtered_out", "-t", "focus")

      expect(normalize(replayed.stdout)).to eq(normalize(serial.stdout))
      expect(normalize(replayed.stdout)).to start_with("Run options: include #{{ focus: true }.inspect}\n\nAll examples were filtered out\n")
    end

    it "prints what rspec prints when no worker found examples" do
      replayed = ReporterHelpers.replay("no_examples", two_workers("no_examples"), "progress")
      serial = ReporterHelpers.run_serial("no_examples")

      expect(normalize(replayed.stdout)).to eq(normalize(serial.stdout))
      expect(normalize(replayed.stdout)).to start_with("No examples found.\n\n\nFinished in N seconds")
    end
  end

  describe "errors outside of examples" do
    it "counts RSpec's load and hook errors once each and reports them in the summary" do
      run_rows(
        [
          load_summary(0),
          { type: "message", message: "\nAn error occurred while loading ./spec/broken_spec.rb.\nFailure/Error: 1 / 0" },
          { type: "message", message: "\nAn error occurred in a `before(:suite)` hook.\nFailure/Error: raise" },
          { type: "message", message: "Retrying: An error occurred in the app" }
        ]
      )

      expect(reporter.errors_outside_of_examples_count).to eq(2)
      expect(text).to include("Retrying: An error occurred in the app\n")
      expect(text).to include("0 examples, 0 failures, 2 errors occurred outside of examples")
      expect(text).not_to include("No examples found.")
      expect(reporter).not_to be_success
    end
  end

  describe "load time" do
    it "is the longest load time any worker reported" do
      run_rows([load_summary(1, 0.5), load_summary(1, 2.5), load_summary(1, 1.0), example_row("example_passed", "works")])

      expect(reporter.load_time).to eq(2.5)
      expect(text).to include("(files took 2.5 seconds to load)")
    end
  end

  describe "workers that hang or crash" do
    it "reports them on stderr, recaps them before the summary and counts them" do
      reporter.report(0) do |r|
        r.handle(example_row("example_passed", "works", worker: 1))
        r.worker_hung(2, ["spec/a_spec.rb", "spec/b_spec.rb"], "Thread 1 backtrace:\n  sleep", 60.0)
        r.worker_crashed(3, ["spec/c_spec.rb"], "SIGKILL")
      end
      hung = "Worker 2 did not exit 60s after finishing RSpec; killed. Files: spec/a_spec.rb spec/b_spec.rb"
      crashed = "Worker 3 exited with status SIGKILL before finishing. Files: spec/c_spec.rb"

      expect(err.string).to eq("#{hung}\nThread 1 backtrace:\n  sleep\n#{crashed}\n")
      expect(text).to include("\nWorker errors:\n  #{hung}\n  #{crashed}\n")
      expect(text).to include("1 example, 0 failures, 2 worker errors\n")
      expect(reporter.worker_errors).to eq(2)
      expect(reporter).not_to be_success
    end

    it "omits the timeout when it is unknown" do
      reporter.report(0) { |r| r.worker_hung(1, ["spec/a_spec.rb"], nil) }

      expect(err.string).to eq("Worker 1 did not exit after finishing RSpec; killed. Files: spec/a_spec.rb\n")
      expect(text).to include("0 examples, 0 failures, 1 worker error\n")
    end
  end

  describe "#handle" do
    it "returns :failure only for failed examples and keeps the example lists" do
      results = []
      reporter.report(0) do |r|
        results << r.handle(example_row("example_passed", "a"))
        results << r.handle(example_row("example_failed", "b", index: 2))
        results << r.handle(example_row("example_pending", "c", index: 3, skipped: true, pending_message: "later"))
        results << r.handle(type: "close")
        results << r.handle(type: "deprecation_summary")
        results << r.handle(type: "job_finished", job_id: 1, exit_code: 1)
      end

      expect(results).to eq([nil, :failure, nil, nil, nil, nil])
      expect(reporter.examples.map(&:description)).to eq(%w[a b c])
      expect(reporter.failed_examples.map(&:description)).to eq(["b"])
      expect(reporter.pending_examples.map(&:description)).to eq(["c"])
      expect(err.string).to eq("")
      expect(text).to include("3 examples, 1 failure, 1 pending")
    end

    it "warns about rows it does not know" do
      reporter.report(0) { |r| r.handle(type: "bogus") }

      expect(err.string).to include('Unhandled message in main process: {:type=>"bogus"}')
        .or include('Unhandled message in main process: {type: "bogus"}')
    end

    it "uses example ids in rerun commands when failures share a location" do
      run_rows([example_row("example_failed", "first", index: 1, line: 5),
                example_row("example_failed", "second", index: 2, line: 5)])

      expect(text).to match(%r{rspec '?\./spec/group_spec\.rb\[1:1\]'? # Group first})
      expect(text).to match(%r{rspec '?\./spec/group_spec\.rb\[1:2\]'? # Group second})
    end
  end

  describe "--print-failed-group" do
    let(:files) { { 1 => %w[spec/a_spec.rb spec/b_spec.rb], 2 => %w[spec/c_spec.rb], 3 => %w[spec/d_spec.rb] } }

    it "prints the files of each worker that failed, in the order they ran" do
      reporter.print_failed_group = true
      reporter.worker_files = files
      reporter.report(0) do |r|
        r.handle(example_row("example_passed", "ok", worker: 1))
        r.handle(example_row("example_failed", "bad", index: 2, worker: 2))
        r.worker_crashed(3, files[3], "SIGKILL")
      end

      expect(text).to end_with(
        "Group that failed (worker 2): spec/c_spec.rb\nGroup that failed (worker 3): spec/d_spec.rb\n\n"
      )
    end

    it "lists every group when rows carry no worker ids" do
      reporter.report(0) { |r| r.handle(example_row("example_failed", "bad")) }

      expect(reporter.failed_group_lines(files.first(2).to_h)).to eq(
        ["Group that failed (worker 1): spec/a_spec.rb spec/b_spec.rb", "Group that failed (worker 2): spec/c_spec.rb"]
      )
    end

    it "prints nothing unless enabled" do
      reporter.worker_files = files
      reporter.report(0) { |r| r.handle(example_row("example_failed", "bad", worker: 2)) }

      expect(text).not_to include("Group that failed")
    end
  end

  describe "formatter lookup" do
    it "resolves RSpec's built-in names" do
      expect(%w[p progress d doc documentation j json f failures].map { |name| described_class.formatter_class(name) })
        .to eq([RSpec::Core::Formatters::ProgressFormatter] * 2 + [RSpec::Core::Formatters::DocumentationFormatter] * 3 +
               [RSpec::Core::Formatters::JsonFormatter] * 2 + [RSpec::Core::Formatters::FailureListFormatter] * 2)
    end

    it "accepts loaded classes registered with RSpec or implementing a formatter notification" do
      registered = Class.new { RSpec::Core::Formatters.register(self, :example_passed) }
      legacy = Class.new { def example_failed(_notification); end }
      stub_const("ReporterSpecRegistered", registered)
      stub_const("ReporterSpec::Legacy", legacy)

      expect(described_class.formatter_class("ReporterSpecRegistered")).to equal(registered)
      expect(described_class.formatter_class("ReporterSpec::Legacy")).to equal(legacy)
      expect(described_class.formatter_class("::RSpec::Core::Formatters::JsonFormatter"))
        .to equal(RSpec::Core::Formatters::JsonFormatter)
    end

    it "requires a formatter named after the constant like rspec --format does" do
      begin
        $LOAD_PATH.unshift(ReporterHelpers.fixture_path("formatters"))
        klass = described_class.formatter_class("ReporterSpecAutoloadedFormatter")

        expect(klass.name).to eq("ReporterSpecAutoloadedFormatter")
      ensure
        $LOAD_PATH.delete(ReporterHelpers.fixture_path("formatters"))
      end
    end

    it "rejects names that are not constant paths without evaluating them" do
      ["Kernel.exit", "system('true')", "`id`", "progress; exit", "Foo::bar", "foo", "Foo::", "::"].each do |name|
        expect { described_class.formatter_class(name) }.to raise_error(TurboTests::Error, /Formatter '.*' unknown/)
      end
    end

    it "rejects constants that are not formatters" do
      %w[String IO Kernel RSpec TurboTests::FakeExample].each do |name|
        expect { described_class.formatter_class(name) }
          .to raise_error(TurboTests::Error, "'#{name}' is not an RSpec formatter: it implements none of the RSpec formatter notifications.")
      end
    end

    it "rejects constants that cannot be found" do
      expect { described_class.formatter_class("TurboTestsNoSuchFormatter") }
        .to raise_error(TurboTests::Error, /Formatter 'TurboTestsNoSuchFormatter' could not be found .*--require/)
    end

    it "fails before opening any output file" do
      path = File.join(ReporterHelpers::REPO_ROOT, "tmp", "reporter_spec", "never_created.txt")

      expect { described_class.from_config([{ name: "String", outputs: [path] }], RSpec::Core::Time.now, nil, false) }
        .to raise_error(TurboTests::Error)
      expect(File.exist?(path)).to be(false)
    end

    it "writes formatter output to files, creating their directory" do
      dir = File.join(ReporterHelpers::REPO_ROOT, "tmp", "reporter_spec_#{Process.pid}")
      path = File.join(dir, "nested", "progress.txt")
      begin
        file_reporter = described_class.from_config(
          [{ name: "p", outputs: [path] }], RSpec::Core::Time.now, nil, false, out: out, err: err
        )
        file_reporter.report(1) { |r| r.handle(example_row("example_passed", "works")) }

        expect(ReporterHelpers.strip_ansi(File.read(path))).to start_with(".\n\nFinished in ")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "sends messages to RSpec's fallback when no formatter handles them" do
      summary_only = Class.new do
        RSpec::Core::Formatters.register(self, :dump_summary)

        def initialize(output)
          @output = output
        end

        def dump_summary(summary)
          @output.puts("summary: #{summary.totals_line}")
        end
      end
      stub_const("ReporterSpecSummaryOnly", summary_only)
      quiet = described_class.from_config(
        [{ name: "ReporterSpecSummaryOnly", outputs: ["-"] }], RSpec::Core::Time.now, nil, false, out: out, err: err
      )
      quiet.report(0) { |r| r.handle(type: "message", message: "hello from a worker") }

      expect(text).to eq("hello from a worker\nNo examples found.\nsummary: 0 examples, 0 failures\n")
    end
  end

  describe ".count_examples" do
    let(:junit) { ReporterHelpers.fixture_path("junit") }

    it "counts the examples rspec --dry-run finds, ignoring formatter options" do
      count = Dir.chdir(junit) do
        described_class.count_examples(["spec"], ["--format", "documentation", "-fp", "--out=dry_run.txt", "--order", "defined"])
      end

      expect(count).to eq(7)
      expect(File.exist?(File.join(junit, "dry_run.txt"))).to be(false)
    end

    it "honours rspec arguments such as tags" do
      count = Dir.chdir(junit) { described_class.count_examples(["spec"], ["--tag", "nonexistent"]) }

      expect(count).to eq(0)
    end

    it "is nil when the command prints no JSON" do
      expect(described_class.count_examples(["spec"], [], command: [RbConfig.ruby, "-e", "puts 'no json'"])).to be_nil
    end

    it "finds the summary after other output and falls back to the last count" do
      expect(described_class.parse_example_count(%(noise {"x":1}\n{"version":"3.12.1","summary":{"example_count":4}}))).to eq(4)
      expect(described_class.parse_example_count(%({"version":"3.12.1","summary":{"example_count":5}}\ntrailing))).to eq(5)
      expect(described_class.parse_example_count("garbage")).to be_nil
    end

    it "drops formatter options only" do
      args = %w[-f d --format=json -fp -o out.txt --out x --out=y -oz --tag focus -t ~slow --fail-fast --order defined]

      expect(described_class.without_formatter_options(args)).to eq(%w[--tag focus -t ~slow --fail-fast --order defined])
    end
  end
end
