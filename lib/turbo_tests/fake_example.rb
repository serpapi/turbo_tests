# frozen_string_literal: true

require "rspec/core"

module TurboTests
  # Structs reconstructed in the parent process from the JSON rows emitted by
  # workers. They quack enough like RSpec::Core::Example (and friends) for the
  # real RSpec formatters to render them.
  FakeException = Struct.new(:backtrace, :message, :cause)
  class FakeException
    def self.from_obj(obj)
      if obj
        klass =
          Class.new(FakeException) {
            define_singleton_method(:name) do
              obj[:class_name]
            end
          }

        klass.new(
          obj[:backtrace],
          obj[:message],
          FakeException.from_obj(obj[:cause])
        )
      end
    end
  end

  FakeExecutionResult = Struct.new(:example_skipped?, :pending_message, :status, :pending_fixed?, :exception, :pending_exception)
  class FakeExecutionResult
    def self.from_obj(obj)
      new(
        obj[:example_skipped?],
        obj[:pending_message],
        obj[:status].to_sym,
        obj[:pending_fixed?],
        FakeException.from_obj(obj[:exception]),
        FakeException.from_obj(obj[:exception])
      )
    end
  end

  FakeExample = Struct.new(:execution_result, :location, :description, :full_description, :metadata, :location_rerun_argument)
  class FakeExample
    def self.from_obj(obj)
      metadata = obj[:metadata]

      metadata[:shared_group_inclusion_backtrace].map! do |frame|
        RSpec::Core::SharedExampleGroupInclusionStackFrame.new(
          frame[:shared_group_name],
          frame[:inclusion_location]
        )
      end

      metadata[:shared_group_inclusion_backtrace] = metadata.delete(:shared_group_inclusion_backtrace)

      new(
        FakeExecutionResult.from_obj(obj[:execution_result]),
        obj[:location],
        obj[:description],
        obj[:full_description],
        metadata,
        obj[:location_rerun_argument]
      )
    end

    def notification
      RSpec::Core::Notifications::ExampleNotification.for(
        self
      )
    end
  end
end
