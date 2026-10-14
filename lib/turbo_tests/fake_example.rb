# frozen_string_literal: true

require "rspec/core"

module TurboTests
  # Objects rebuilt in the parent process from the rows workers emit. They
  # quack enough like RSpec::Core::Example (and friends) for RSpec's own
  # formatters, RspecJunitFormatter and Fuubar to render them.

  # A real Exception subclass so RSpec's cause traversal (`Exception === cause`)
  # works; one anonymous subclass per original class name, whose `name` is the
  # original class name.
  class FakeException < StandardError
    MAX_CAUSE_DEPTH = 32

    @classes = {}

    class << self
      def from_obj(obj, depth = 0)
        return nil unless obj.is_a?(Hash)

        cause = depth < MAX_CAUSE_DEPTH ? from_obj(obj[:cause], depth + 1) : nil
        class_for(obj[:class_name].to_s).new(obj[:message], obj[:backtrace], cause)
      end

      def class_for(class_name)
        @classes[class_name] ||= begin
          klass = Class.new(FakeException)
          klass.define_singleton_method(:name) { class_name }
          klass.define_singleton_method(:to_s) { class_name }
          klass.define_singleton_method(:inspect) { class_name }
          klass
        end
      end
    end

    attr_reader :backtrace, :cause

    def initialize(message, backtrace, cause)
      @fake_message = message.to_s
      @backtrace = backtrace.is_a?(Array) ? backtrace.map(&:to_s) : nil
      @cause = cause
      super(@fake_message)
    end

    def message
      @fake_message
    end

    def to_s
      @fake_message
    end

    def inspect
      "#<#{self.class.name}: #{@fake_message}>"
    end
  end

  class FakeExecutionResult
    attr_reader :status, :pending_message, :exception, :pending_exception, :run_time

    def self.from_obj(obj, run_time = nil)
      obj ||= {}
      status = obj[:status]

      new(
        status: status && status.to_sym,
        example_skipped: obj[:example_skipped?],
        pending_message: obj[:pending_message],
        pending_fixed: obj[:pending_fixed?],
        exception: FakeException.from_obj(obj[:exception]),
        pending_exception: FakeException.from_obj(obj[:pending_exception]),
        run_time: run_time
      )
    end

    def initialize(status:, example_skipped: false, pending_message: nil, pending_fixed: false,
                   exception: nil, pending_exception: nil, run_time: nil)
      @status = status
      @example_skipped = example_skipped ? true : false
      @pending_message = pending_message
      @pending_fixed = pending_fixed ? true : false
      @exception = exception
      @pending_exception = pending_exception
      @run_time = run_time
    end

    def example_skipped?
      @example_skipped
    end

    def pending_fixed?
      @pending_fixed
    end
    alias pending_fixed pending_fixed?

    def started_at
      nil
    end

    def finished_at
      nil
    end
  end

  # Stands for the example group a row refers to. Rows only describe one
  # group level, so it presents itself as a top-level group.
  class FakeExampleGroup
    attr_reader :description, :location, :file_path, :line_number

    def self.from_obj(obj)
      obj ||= {}
      new(
        description: obj[:description].to_s,
        location: obj[:location],
        file_path: obj[:file_path] || file_path_from(obj[:location]),
        line_number: obj[:line_number]
      )
    end

    def self.file_path_from(location)
      return nil unless location

      location.to_s.sub(/:\d+\z/, "")
    end

    def initialize(description:, location: nil, file_path: nil, line_number: nil)
      @description = description
      @location = location
      @file_path = file_path
      @line_number = line_number
    end

    def parent_groups
      [self]
    end

    def top_level?
      true
    end

    def top_level_description
      description
    end

    def metadata
      @metadata ||= {
        description: description,
        full_description: description,
        location: location,
        file_path: file_path,
        line_number: line_number
      }
    end

    def to_s
      description
    end
    alias inspect to_s
  end

  class FakeExample
    attr_reader :id, :description, :full_description, :location, :location_rerun_argument,
                :file_path, :line_number, :run_time, :execution_result, :metadata, :example_group

    def self.from_obj(obj)
      run_time = obj[:run_time]
      execution_result = FakeExecutionResult.from_obj(obj[:execution_result], run_time)
      group_obj = obj[:top_level_group] || { description: "", location: nil, file_path: obj[:file_path] }
      example_group = FakeExampleGroup.from_obj(group_obj)
      raw_metadata = obj[:metadata] || {}

      metadata = {
        id: obj[:id],
        description: obj[:description],
        full_description: obj[:full_description],
        location: obj[:location],
        file_path: obj[:file_path],
        line_number: obj[:line_number],
        execution_result: execution_result,
        example_group: example_group.metadata,
        shared_group_inclusion_backtrace: inclusion_frames(raw_metadata[:shared_group_inclusion_backtrace]),
        extra_failure_lines: raw_metadata[:extra_failure_lines]
      }

      new(
        id: obj[:id],
        description: obj[:description],
        full_description: obj[:full_description],
        location: obj[:location],
        location_rerun_argument: obj[:location_rerun_argument] || obj[:location],
        file_path: obj[:file_path],
        line_number: obj[:line_number],
        run_time: run_time,
        execution_result: execution_result,
        metadata: metadata,
        example_group: example_group
      )
    end

    def self.inclusion_frames(frames)
      Array(frames).map do |frame|
        RSpec::Core::SharedExampleGroupInclusionStackFrame.new(
          frame[:shared_group_name],
          frame[:inclusion_location]
        )
      end
    end

    def initialize(id:, description:, full_description:, location:, location_rerun_argument:,
                   file_path:, line_number:, run_time:, execution_result:, metadata:, example_group:)
      @id = id
      @description = description.to_s
      @full_description = full_description.to_s
      @location = location
      @location_rerun_argument = location_rerun_argument
      @file_path = file_path
      @line_number = line_number
      @run_time = run_time
      @execution_result = execution_result
      @metadata = metadata
      @example_group = example_group
    end

    def exception
      execution_result.exception
    end

    def pending?
      execution_result.status == :pending
    end

    def skipped?
      execution_result.example_skipped?
    end

    def rerun_argument
      location_rerun_argument
    end

    def notification
      RSpec::Core::Notifications::ExampleNotification.for(self)
    end

    def inspect
      "#<#{self.class.name} #{full_description.inspect} (#{location})>"
    end
  end
end
