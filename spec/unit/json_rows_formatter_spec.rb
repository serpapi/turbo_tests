# frozen_string_literal: true

require "json"
require_relative "../reporter/support/reporter_helpers"

RSpec.describe TurboTests::JsonRowsFormatter do
  EXAMPLE_KEYS = %i[
    id description full_description location location_rerun_argument file_path line_number
    run_time execution_result metadata top_level_group
  ].freeze
  EXECUTION_RESULT_KEYS = %i[status example_skipped? pending_message pending_fixed? exception pending_exception].freeze
  GROUP_KEYS = %i[description location file_path line_number].freeze

  def rows_of(run, type)
    run.rows.select { |row| row[:type] == type }
  end

  def example_named(run, description)
    run.rows.map { |row| row[:example] }.compact.find { |example| example[:description] == description }
  end

  describe "rows written by a real rspec process" do
    let(:run) { ReporterHelpers.run_worker("rows") }

    it "uses only the dedicated descriptor, one JSON object with a type per line" do
      expect(run.status.exitstatus).to eq(1)
      expect(run.stdout).to eq("")
      expect(run.rows).to all(include(:type))
    end

    it "emits rows in RSpec notification order and ends with close" do
      expect(run.rows.map { |row| row[:type] }).to eq(
        %w[
          seed load_summary group_started
          example_passed example_failed example_failed example_failed example_pending example_pending
          message example_passed
          group_started group_started example_failed group_finished group_finished group_finished
          deprecation_summary seed close
        ]
      )
    end

    it "reports the load summary" do
      summary = rows_of(run, "load_summary").first[:summary]

      expect(summary[:count]).to eq(8)
      expect(summary[:load_time]).to be_a(Float)
    end

    it "describes groups with their location" do
      expect(rows_of(run, "group_started").map { |row| row[:group] }).to eq(
        [
          { description: "Rows fixture", location: "./spec/rows_spec.rb:3", file_path: "./spec/rows_spec.rb", line_number: 3 },
          { description: "nested context", location: "./spec/rows_spec.rb:34", file_path: "./spec/rows_spec.rb", line_number: 34 },
          { description: "behaves like a shared behaviour", location: "./spec/rows_spec.rb:35",
            file_path: "./spec/rows_spec.rb", line_number: 35 }
        ]
      )
      expect(rows_of(run, "group_finished").map { |row| row[:group][:description] }).to eq(
        ["behaves like a shared behaviour", "nested context", "Rows fixture"]
      )
    end

    it "describes a passed example" do
      example = example_named(run, "passes")

      expect(example.keys).to match_array(EXAMPLE_KEYS)
      expect(example).to include(
        id: "./spec/rows_spec.rb[1:1]",
        full_description: "Rows fixture passes",
        location: "./spec/rows_spec.rb:4",
        location_rerun_argument: "./spec/rows_spec.rb:4",
        file_path: "./spec/rows_spec.rb",
        line_number: 4,
        top_level_group: { description: "Rows fixture", location: "./spec/rows_spec.rb:3",
                           file_path: "./spec/rows_spec.rb", line_number: 3 }
      )
      expect(example[:run_time]).to be_a(Float).and be >= 0
      expect(example[:execution_result]).to eq(
        status: "passed", "example_skipped?": false, pending_message: nil, "pending_fixed?": false,
        exception: nil, pending_exception: nil
      )
      expect(example[:metadata]).to eq(shared_group_inclusion_backtrace: [], extra_failure_lines: nil)
    end

    it "serializes the exception and its cause recursively" do
      exception = example_named(run, "fails with a cause")[:execution_result][:exception]

      expect(exception.keys).to eq(%i[class_name message backtrace cause])
      expect(exception).to include(class_name: "RuntimeError", message: "outer problem")
      expect(exception[:backtrace]).to all(be_a(String))
      expect(exception[:backtrace].first).to match(%r{/fixtures/reporter/rows/spec/rows_spec\.rb:10:in [`']})
      expect(exception[:cause]).to include(class_name: "ArgumentError", message: "inner problem", cause: nil)
      expect(exception[:cause][:backtrace].first).to include("spec/rows_spec.rb:8")
    end

    it "scrubs bytes that are not UTF-8 instead of failing to encode the row" do
      failed = example_named(run, "fails with binary bytes in the message")[:execution_result][:exception]
      extra = example_named(run, "records extra failure lines")[:metadata][:extra_failure_lines]

      expect(failed[:message]).to eq("bad bytes: \uFFFD\uFFFD")
      expect(extra).to eq(["extra line \uFFFD", "second line"])
      expect(rows_of(run, "message").map { |row| row[:message] }).to eq(["message bytes: \uFFFD"])
    end

    it "keeps the pending exception apart from the failure exception" do
      pending = example_named(run, "is pending")[:execution_result]
      skipped = example_named(run, "is skipped")[:execution_result]

      expect(pending.keys).to eq(EXECUTION_RESULT_KEYS)
      expect(pending).to include(status: "pending", "example_skipped?": false, pending_message: "not implemented yet",
                                 exception: nil)
      expect(pending[:pending_exception]).to include(class_name: "RSpec::Expectations::ExpectationNotMetError")
      expect(skipped).to include(status: "pending", "example_skipped?": true, pending_message: "later",
                                 exception: nil, pending_exception: nil)
    end

    it "includes shared group frames and the top-level group of nested examples" do
      example = example_named(run, "fails inside shared examples")

      expect(example[:id]).to eq("./spec/rows_spec.rb[1:8:1:1]")
      expect(example[:location_rerun_argument]).to eq("./spec/rows_spec.rb:35")
      expect(example[:metadata][:shared_group_inclusion_backtrace]).to match(
        [{ shared_group_name: "a shared behaviour", inclusion_location: a_string_starting_with("./spec/rows_spec.rb:35:in ") }]
      )
      expect(example[:top_level_group]).to include(description: "Rows fixture", file_path: "./spec/rows_spec.rb")
    end

    it "reports the real seed and that a defined order did not use it" do
      expect(rows_of(run, "seed")).to all(include(seed: a_kind_of(Integer), seed_used: false))
    end

    it "does not profile unless RSpec profiles" do
      expect(rows_of(run, "dump_profile")).to be_empty
    end
  end

  describe "seed rows" do
    it "reports seed_used when .rspec has --order random" do
      seeds = rows_of(ReporterHelpers.run_worker("random_order/rspec_file"), "seed")

      expect(seeds.size).to eq(2)
      expect(seeds).to all(include(seed_used: true))
      expect(seeds.map { |row| row[:seed] }.uniq.size).to eq(1)
    end

    it "reports seed_used when spec_helper sets config.order = :random" do
      expect(rows_of(ReporterHelpers.run_worker("random_order/spec_helper"), "seed")).to all(include(seed_used: true))
    end

    it "reports a forced seed" do
      seeds = rows_of(ReporterHelpers.run_worker("defined_order", "--seed", "4242"), "seed")

      expect(seeds).to eq([{ type: "seed", seed: 4242, seed_used: true }] * 2)
    end

    it "reports seed_used false for a defined order" do
      expect(rows_of(ReporterHelpers.run_worker("defined_order"), "seed")).to all(include(seed_used: false))
    end
  end

  describe "deprecation rows" do
    let(:run) { ReporterHelpers.run_worker("deprecations") }

    it "forwards every deprecation notification and the summary notification" do
      deprecations = rows_of(run, "deprecation")

      expect(deprecations.size).to eq(2)
      expect(deprecations.uniq.size).to eq(1)
      expect(deprecations.first.keys).to eq(%i[type message deprecated replacement call_site])
      expect(deprecations.first).to include(message: nil, deprecated: "foo", replacement: "bar")
      expect(deprecations.first[:call_site]).to match(%r{spec/spec_helper\.rb:3:in [`'](DeprecatedHelper#)?call_deprecated_helper'})
      expect(rows_of(run, "deprecation_summary")).to eq([{ type: "deprecation_summary" }])
    end
  end

  describe "dump_profile rows" do
    let(:run) { ReporterHelpers.run_worker("profile") }
    let(:profile) { rows_of(run, "dump_profile").first }

    it "sends the job's top N examples and top-level groups with plain values" do
      expect(rows_of(run, "dump_profile").size).to eq(1)
      expect(profile.keys).to eq(%i[type slowest_examples slowest_groups duration number_of_examples])
      expect(profile[:number_of_examples]).to eq(3)
      expect(profile[:duration]).to be_a(Float)
      expect(profile[:slowest_examples].map { |example| example[:description] }).to eq(
        ["sleeps 0.60", "sleeps 0.35", "sleeps 0.20"]
      )
      expect(profile[:slowest_examples].first.keys).to eq(%i[id description full_description location run_time])
      expect(profile[:slowest_examples].first).to include(
        id: "./spec/second_spec.rb[1:3]", full_description: "Profile second sleeps 0.60",
        location: "./spec/second_spec.rb:4", run_time: be >= 0.6
      )
      expect(profile[:slowest_groups].map { |group| group.values_at(:description, :location, :count) }).to eq(
        [["Profile second", "./spec/second_spec.rb:1", 3], ["Profile first", "./spec/first_spec.rb:1", 3]]
      )
      expect(profile[:slowest_groups].map { |group| group[:total_time] }).to all(be_a(Float).and(be >= 0.5))
    end

    it "sends groups even when the job has a single top-level group" do
      single = rows_of(ReporterHelpers.run_worker("profile", "spec/first_spec.rb"), "dump_profile").first

      expect(single[:slowest_examples].map { |example| example[:description] }).to eq(
        ["sleeps 0.35", "sleeps 0.20", "sleeps 0.02"]
      )
      expect(single[:slowest_groups].map { |group| group[:description] }).to eq(["Profile first"])
    end
  end

  describe "mixed transport" do
    it "prefixes rows on stdout with RSPEC_FORMATTER_OUTPUT_ID when there is no dedicated descriptor" do
      run = ReporterHelpers.run_worker(
        "defined_order", "spec/a_spec.rb",
        env: { "TURBO_TESTS_ROWS_FD" => nil, "RSPEC_FORMATTER_OUTPUT_ID" => "row-marker:" }
      )
      lines = run.stdout.lines

      expect(run.rows).to eq([])
      expect(lines).not_to be_empty
      expect(lines).to all(start_with("row-marker:{"))
      expect(JSON.parse(lines.last.sub("row-marker:", ""))).to eq("type" => "close")
    end
  end

  describe ".without_worker_frames" do
    let(:own) { "#{File.expand_path("../../lib", __dir__)}/turbo_tests" }
    let(:rspec_frame) { "/gems/rspec-core-3.12.1/lib/rspec/core/example.rb:263:in `instance_exec'" }

    it "drops turbo_tests' worker loop frames below RSpec's runner and keeps the frames above" do
      backtrace = [
        "#{own}/reporter.rb:10:in `handle'",
        "/project/spec/a_spec.rb:3:in `block (2 levels) in <top (required)>'",
        rspec_frame,
        "#{own}/worker.rb:251:in `block in execute'",
        "/project/spec/support/around.rb:4:in `call'",
        "#{own}/preloader.rb:135:in `worker'",
        "-e:1:in `<main>'"
      ]

      expect(described_class.without_worker_frames(backtrace)).to eq(backtrace.first(3) + ["/project/spec/support/around.rb:4:in `call'"])
    end

    it "keeps backtraces without RSpec frames as they are" do
      backtrace = ["#{own}/worker.rb:1:in `x'", "-e:1:in `<main>'"]

      expect(described_class.without_worker_frames(backtrace)).to eq(backtrace)
      expect(described_class.without_worker_frames(nil)).to be_nil
    end
  end

  describe ".sanitize" do
    subject(:sanitized) { described_class.sanitize(value) }

    context "with strings in other encodings" do
      let(:value) do
        {
          binary: "caf\xC3\xA9 \xFF".b,
          latin1: "caf\xE9".dup.force_encoding(Encoding::ISO_8859_1),
          utf16: "hi".encode(Encoding::UTF_16LE),
          frozen: "ok"
        }
      end

      it "returns valid UTF-8 strings" do
        expect(sanitized).to eq(binary: "café \uFFFD", latin1: "café", utf16: "hi", frozen: "ok")
        expect(sanitized.values.map(&:encoding).uniq).to eq([Encoding::UTF_8])
        expect(sanitized.values).to all(be_valid_encoding)
      end
    end

    context "with values JSON cannot represent as is" do
      let(:string_subclass) { Class.new(String) }
      let(:value) do
        {
          symbol: :passed,
          nan: Float::NAN,
          infinity: Float::INFINITY,
          rational: Rational(1, 4),
          object: Object.new.tap { |object| object.define_singleton_method(:to_s) { "custom" } },
          subclass: string_subclass.new("text"),
          nested: [{ "key" => [1, 2.5, true, false, nil] }]
        }
      end

      it "converts them to plain JSON types" do
        expect(sanitized).to eq(
          symbol: "passed", nan: nil, infinity: nil, rational: 0.25, object: "custom", subclass: "text",
          nested: [{ "key" => [1, 2.5, true, false, nil] }]
        )
        expect(sanitized[:subclass].class).to eq(String)
        expect(JSON.parse(JSON.generate(sanitized))).to include("nan" => nil, "subclass" => "text")
      end
    end

    context "with a self-referencing structure" do
      let(:value) { [].tap { |array| array << array } }

      it "stops descending and keeps the row encodable" do
        expect { JSON.generate(sanitized) }.not_to raise_error
      end
    end
  end
end
