# frozen_string_literal: true

require "json"
require_relative "../reporter/support/reporter_helpers"

RSpec.describe TurboTests::FakeExample do
  def row_for(run, description)
    run.rows.map { |row| row[:example] }.compact.find { |example| example[:description] == description } ||
      raise("no example row #{description.inspect}")
  end

  def normalize(text)
    ReporterHelpers.normalize_timing(ReporterHelpers.strip_ansi(text))
  end

  def normalize_junit(xml)
    xml.gsub(/ time="[^"]*"/, ' time="T"')
       .gsub(/ (?:timestamp|hostname)="[^"]*"/, "")
       .gsub(%r{<property name="seed" value="\d+"/>}, "")
  end

  let(:run) { ReporterHelpers.run_worker("junit") }

  describe ".from_obj" do
    subject(:example) { described_class.from_obj(row_for(run, "fails with a cause")) }

    it "exposes identity, timing and location like RSpec::Core::Example" do
      expect(example.id).to eq("./spec/junit_spec.rb[1:2]")
      expect(example.description).to eq("fails with a cause")
      expect(example.full_description).to eq("JUnit fixture fails with a cause")
      expect(example.location).to eq("./spec/junit_spec.rb:10")
      expect(example.location_rerun_argument).to eq("./spec/junit_spec.rb:10")
      expect(example.file_path).to eq("./spec/junit_spec.rb")
      expect(example.line_number).to eq(10)
      expect(example.run_time).to be_a(Float)
      expect(example.execution_result.run_time).to eq(example.run_time)
      expect(example.execution_result.status).to eq(:failed)
    end

    it "provides the metadata formatters read" do
      expect(example.metadata).to include(
        id: "./spec/junit_spec.rb[1:2]",
        location: "./spec/junit_spec.rb:10",
        file_path: "./spec/junit_spec.rb",
        line_number: 10,
        full_description: "JUnit fixture fails with a cause",
        description: "fails with a cause",
        shared_group_inclusion_backtrace: [],
        extra_failure_lines: nil,
        execution_result: example.execution_result,
        example_group: include(file_path: "./spec/junit_spec.rb", description: "JUnit fixture")
      )
    end

    it "rebuilds the exception chain as exceptions named after the original classes" do
      exception = example.exception

      expect(exception).to be_an(Exception)
      expect(exception.class.name).to eq("RuntimeError")
      expect(exception.class.to_s).to eq("RuntimeError")
      expect(exception.message).to eq("outer problem")
      expect(exception.to_s).to eq("outer problem")
      expect(exception.backtrace.first).to match(%r{junit/spec/junit_spec\.rb:14:in })
      expect(exception.cause).to be_an(Exception)
      expect(exception.cause.class.name).to eq("ArgumentError")
      expect(exception.cause.message).to eq("inner problem")
      expect(exception.cause.cause).to be_nil
    end

    it "presents the top-level group as the example group" do
      group = example.example_group

      expect(group.description).to eq("JUnit fixture")
      expect(group.location).to eq("./spec/junit_spec.rb:7")
      expect(group.file_path).to eq("./spec/junit_spec.rb")
      expect(group.line_number).to eq(7)
      expect(group.parent_groups).to eq([group])
      expect(group.metadata).to include(description: "JUnit fixture", file_path: "./spec/junit_spec.rb")
    end

    it "rebuilds shared example group frames" do
      shared = described_class.from_obj(row_for(run, "fails inside shared examples"))
      frames = shared.metadata[:shared_group_inclusion_backtrace]

      expect(frames).to all(be_a(RSpec::Core::SharedExampleGroupInclusionStackFrame))
      expect(frames.map(&:shared_group_name)).to eq(["a shared behaviour"])
      expect(frames.first.description).to start_with('Shared Example Group: "a shared behaviour" called from ./spec/junit_spec.rb:33')
    end

    it "keeps one exception class per original class name" do
      first = TurboTests::FakeException.from_obj(class_name: "Custom::Error", message: "a", backtrace: nil)
      second = TurboTests::FakeException.from_obj(class_name: "Custom::Error", message: "b", backtrace: [])

      expect(first.class).to equal(second.class)
      expect(first.backtrace).to be_nil
      expect(TurboTests::FakeException.from_obj(nil)).to be_nil
    end
  end

  describe "#notification" do
    it "is the notification class RSpec uses for each outcome" do
      notification_class = lambda do |description|
        described_class.from_obj(row_for(run, description)).notification.class
      end

      expect(notification_class.call("passes")).to eq(RSpec::Core::Notifications::ExampleNotification)
      expect(notification_class.call("fails with a cause")).to eq(RSpec::Core::Notifications::FailedExampleNotification)
      expect(notification_class.call("is pending"))
        .to eq(RSpec::Core::Notifications::PendingExampleFailedAsExpectedNotification)
      expect(notification_class.call("is skipped")).to eq(RSpec::Core::Notifications::SkippedExampleNotification)
    end
  end

  describe "rendering through real formatters in a parent process" do
    %w[progress documentation].each do |format|
      it "matches a serial rspec run with --format #{format}" do
        serial = ReporterHelpers.run_serial("junit", "--format", format)
        replayed = ReporterHelpers.replay("junit", run.rows, format)

        expect(replayed.stderr).to eq("")
        expect(serial.status.exitstatus).to eq(1)
        expect(normalize(replayed.stdout)).to eq(normalize(serial.stdout))
      end
    end

    it "matches a serial rspec run with --format json" do
      serial = JSON.parse(ReporterHelpers.run_serial("junit", "--format", "json").stdout)
      replayed = JSON.parse(ReporterHelpers.replay("junit", run.rows, "json").stdout)
      untimed = lambda do |output|
        output["summary"].delete("duration")
        output["examples"].each { |example| example.delete("run_time") }
        output
      end

      expect(untimed.call(replayed)).to eq(untimed.call(serial))
    end

    it "matches RspecJunitFormatter's XML from a serial run" do
      unless ReporterHelpers.available_outside_bundle?("rspec_junit_formatter")
        skip "rspec_junit_formatter is not installed"
      end

      rows = ReporterHelpers.run_worker("junit", unbundled: true).rows
      serial = ReporterHelpers.run_serial(
        "junit", "--require", "rspec_junit_formatter", "--format", "RspecJunitFormatter", unbundled: true
      )
      replayed = ReporterHelpers.replay(
        "junit", rows, "RspecJunitFormatter", requires: ["rspec_junit_formatter"], unbundled: true
      )

      expect(replayed.stderr).to eq("")
      expect(replayed.stdout).to include('<testsuite name="rspec" tests="7" skipped="2" failures="4" errors="0"')
      expect(replayed.stdout).to include("--- Caused by: ---")
      expect(normalize_junit(replayed.stdout)).to eq(normalize_junit(serial.stdout))
    end

    it "drives Fuubar's progress bar with the dry-run example count" do
      skip "fuubar is not installed" unless ReporterHelpers.available_outside_bundle?("fuubar")

      rows = ReporterHelpers.run_worker("fuubar", unbundled: true).rows
      count = Bundler.with_unbundled_env do
        Dir.chdir(ReporterHelpers.fixture_path("fuubar")) { TurboTests::Reporter.count_examples(["spec"]) }
      end
      replayed = ReporterHelpers.replay(
        "fuubar", rows, "Fuubar", requires: ["fuubar"], count: count, unbundled: true
      )
      output = ReporterHelpers.strip_ansi(replayed.stdout)

      expect(count).to eq(5)
      expect(replayed.stderr).to eq("")
      expect(replayed.status).to be_success
      expect(output).to match(/^Progress: \|=+\|$/)
      expect(output).to include("1) Fuubar fixture fails")
      expect(output).to include("5 examples, 1 failure, 1 pending")
    end
  end
end
