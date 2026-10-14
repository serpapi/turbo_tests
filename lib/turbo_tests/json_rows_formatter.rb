# frozen_string_literal: true

require "json"
require "rspec/core"
require "rspec/core/formatters"
require "rspec/core/notifications"

require_relative "protocol"

module RSpecExt
  # First interrupt: let RSpec stop after the current example and report.
  # Second interrupt: exit immediately. RSpec's own version keys the hard exit
  # on `wants_to_quit`, which is also set by `fail_fast` and load errors, so a
  # single INT after those would skip after(:suite) and at_exit handlers.
  def handle_interrupt
    @turbo_tests_interrupts = (@turbo_tests_interrupts || 0) + 1
    if @turbo_tests_interrupts > 1
      exit!(1)
    else
      RSpec.world.wants_to_quit = true
    end
  end
end

RSpec::Core::Runner.singleton_class.prepend(RSpecExt)

module TurboTests
  # The RSpec formatter every worker runs: turns RSpec notifications into JSON
  # rows (see TurboTests::Protocol) that the parent replays into the user's
  # formatters. Rows are built from plain Hash/Array/String/Numeric/true/false/nil
  # values only and every string is valid UTF-8, so JSON.generate never raises
  # on binary spec output and ActiveSupport's #to_json overrides never apply.
  class JsonRowsFormatter
    RSpec::Core::Formatters.register(
      self,
      :start,
      :close,
      :example_started,
      :example_failed,
      :example_passed,
      :example_pending,
      :example_group_started,
      :example_group_finished,
      :message,
      :deprecation,
      :deprecation_summary,
      :dump_profile,
      :seed
    )

    MAX_CAUSE_DEPTH = 32
    MAX_NESTING = 64
    OWN_FRAMES = "#{File.expand_path("..", __dir__)}/turbo_tests/"
    BOOTSTRAP_FRAME = /\A-e:\d+:in /.freeze

    attr_reader :output

    def initialize(output)
      @output = output
      @writer = TurboTests::Protocol.default_writer(output)
      @groups = {}
    end

    def start(notification)
      @groups = {}
      output_row(
        type: :load_summary,
        summary: {
          count: notification.count,
          load_time: notification.load_time
        }
      )
    end

    def example_group_started(notification)
      group = notification.group
      if top_level?(group)
        @groups[group] = {
          start: RSpec::Core::Time.now,
          count: 0,
          description: group.description,
          location: group.metadata[:location]
        }
      end

      output_row(
        type: :group_started,
        group: group_to_json(group)
      )
    end

    def example_group_finished(notification)
      group = notification.group
      stats = @groups[group]
      stats[:total_time] = RSpec::Core::Time.now - stats[:start] if stats

      output_row(
        type: :group_finished,
        group: group_to_json(group)
      )
    end

    def example_started(notification)
      stats = @groups[top_level_group_of(notification.example)]
      stats[:count] += 1 if stats
    end

    def example_passed(notification)
      output_row(
        type: :example_passed,
        example: example_to_json(notification.example)
      )
    end

    def example_pending(notification)
      output_row(
        type: :example_pending,
        example: example_to_json(notification.example)
      )
    end

    def example_failed(notification)
      output_row(
        type: :example_failed,
        example: example_to_json(notification.example)
      )
    end

    def message(notification)
      output_row(
        type: :message,
        message: notification.message
      )
    end

    def deprecation(notification)
      output_row(
        type: :deprecation,
        message: notification.message,
        deprecated: notification.deprecated,
        replacement: notification.replacement,
        call_site: notification.call_site
      )
    end

    def deprecation_summary(_notification)
      output_row(type: :deprecation_summary)
    end

    # Sends this job's top N examples and top N (at least 2) top-level groups,
    # ranked like RSpec::Core::Notifications::ProfileNotification does. The
    # parent merges them into one global top N, which is exact because the
    # global top N is a subset of the union of per-job top N lists.
    def dump_profile(profile)
      number_of_examples = profile.number_of_examples.to_i

      groups = @groups.values.select { |stats| stats[:total_time] && stats[:count] > 0 }
      groups = groups.sort_by { |stats| -(stats[:total_time].to_f / stats[:count]) }
      groups = groups.first([number_of_examples, 2].max)

      output_row(
        type: :dump_profile,
        slowest_examples: profile.slowest_examples.map { |example| profile_example_to_json(example) },
        slowest_groups: groups.map { |stats| profile_group_to_json(stats) },
        duration: profile.duration,
        number_of_examples: number_of_examples
      )
    end

    def seed(notification)
      output_row(
        type: :seed,
        seed: notification.seed,
        seed_used: notification.seed_used?
      )
    end

    def close(_notification)
      output_row(type: :close)
    end

    # Deep-copies a row into JSON-safe core types with valid UTF-8 strings.
    def self.sanitize(value, depth = 0)
      return safe_string(value) if depth > MAX_NESTING

      case value
      when Hash
        result = {}
        value.each do |key, item|
          result[key.is_a?(Symbol) ? key : safe_string(key)] = sanitize(item, depth + 1)
        end
        result
      when Array
        value.map { |item| sanitize(item, depth + 1) }
      when String, Symbol
        utf8(value.to_s)
      when Integer, true, false, nil
        value
      when Float
        value.finite? ? value : nil
      when Numeric
        float = value.to_f
        float.finite? ? float : nil
      else
        safe_string(value)
      end
    end

    # The worker loop's own frames sit below RSpec's runner frames and have no
    # counterpart in a serial rspec run; frames above them are kept.
    def self.without_worker_frames(backtrace)
      return backtrace unless backtrace.is_a?(Array)

      runner = backtrace.index { |line| RSpec::CallerFilter::LIB_REGEX =~ line.to_s }
      return backtrace unless runner

      backtrace[0..runner] + backtrace[(runner + 1)..-1].reject do |line|
        line = line.to_s
        line.start_with?(OWN_FRAMES) || BOOTSTRAP_FRAME =~ line
      end
    end

    def self.utf8(string)
      copy = String.new(string)
      encoding = copy.encoding
      if encoding == Encoding::UTF_8 || encoding == Encoding::BINARY || encoding == Encoding::US_ASCII
        copy.force_encoding(Encoding::UTF_8)
        copy.valid_encoding? ? copy : copy.scrub
      else
        copy.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    rescue EncodingError
      String.new(string).force_encoding(Encoding::UTF_8).scrub
    end

    def self.safe_string(value)
      string = value.to_s
      utf8(string.is_a?(String) ? string : "#<#{value.class}>")
    rescue StandardError
      "#<#{value.class.name}>"
    end

    private

    def top_level?(group)
      group.respond_to?(:top_level?) ? group.top_level? : true
    end

    def top_level_group_of(example)
      group = example.example_group
      group.respond_to?(:parent_groups) ? group.parent_groups.last : group
    end

    def exception_to_json(exception, depth = 0)
      return nil unless exception

      cause = exception.respond_to?(:cause) ? exception.cause : nil
      cause = nil if cause.equal?(exception) || depth >= MAX_CAUSE_DEPTH

      {
        class_name: exception.class.name.to_s,
        message: exception_message(exception),
        backtrace: self.class.without_worker_frames(exception.backtrace),
        cause: exception_to_json(cause, depth + 1)
      }
    end

    def exception_message(exception)
      exception.message.to_s
    rescue StandardError => e
      "A #{exception.class} for which `exception.message.to_s` raises #{e.class}."
    end

    def execution_result_to_json(result)
      {
        :status => result.status,
        :example_skipped? => result.example_skipped?,
        :pending_message => result.pending_message,
        :pending_fixed? => result.pending_fixed?,
        :exception => exception_to_json(result.exception),
        :pending_exception => exception_to_json(result.pending_exception)
      }
    end

    def stack_frame_to_json(frame)
      {
        shared_group_name: frame.shared_group_name,
        inclusion_location: frame.inclusion_location
      }
    end

    def example_to_json(example)
      metadata = example.metadata

      {
        id: example.id,
        description: example.description,
        full_description: example.full_description,
        location: example.location,
        location_rerun_argument: example.location_rerun_argument,
        file_path: metadata[:file_path],
        line_number: metadata[:line_number],
        run_time: example.execution_result.run_time,
        execution_result: execution_result_to_json(example.execution_result),
        metadata: {
          shared_group_inclusion_backtrace:
            Array(metadata[:shared_group_inclusion_backtrace]).map { |frame| stack_frame_to_json(frame) },
          extra_failure_lines: metadata[:extra_failure_lines]
        },
        top_level_group: group_to_json(top_level_group_of(example))
      }
    end

    def group_to_json(group)
      metadata = group.metadata

      {
        description: group.description,
        location: metadata[:location],
        file_path: metadata[:file_path],
        line_number: metadata[:line_number]
      }
    end

    def profile_example_to_json(example)
      {
        id: example.id,
        description: example.description,
        full_description: example.full_description,
        location: example.location,
        run_time: example.execution_result.run_time
      }
    end

    def profile_group_to_json(stats)
      {
        location: stats[:location],
        description: stats[:description],
        total_time: stats[:total_time],
        count: stats[:count]
      }
    end

    def output_row(row)
      @writer.write(self.class.sanitize(row))
    end
  end
end
