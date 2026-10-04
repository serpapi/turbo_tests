# frozen_string_literal: true

module TurboTests
  # before_fork / after_fork hooks for the fork pool, configured with
  #
  #   TurboTests.configure do |config|
  #     config.before_fork { ... }            # in the preloader, once
  #     config.after_fork { |worker| ... }    # in every forked worker
  #   end
  #
  # usually from `.turbo_tests.rb` in the project root (loaded automatically
  # by the preloader and by spawned workers). Default hooks disconnect
  # ActiveRecord before forking and reconnect it (re-reading the database
  # configuration with the worker's TEST_ENV_NUMBER) after; set
  # `config.default_hooks = false` to opt out.
  class Hooks
    PROJECT_FILE = ".turbo_tests.rb"

    attr_accessor :default_hooks

    def initialize
      @before_fork = []
      @after_fork = []
      @default_hooks = true
    end

    def before_fork(&block)
      @before_fork << block if block
      self
    end

    def after_fork(&block)
      @after_fork << block if block
      self
    end

    def run_before_fork
      Hooks.default_before_fork if @default_hooks
      @before_fork.each(&:call)
    end

    def run_after_fork(worker_number)
      Hooks.default_after_fork(worker_number) if @default_hooks
      @after_fork.each { |hook| hook.call(worker_number) }
    end

    def self.load_project_file(path = PROJECT_FILE)
      return false unless File.file?(path)

      load File.expand_path(path)
      true
    end

    def self.active_record
      defined?(::ActiveRecord::Base) ? ::ActiveRecord : nil
    end

    def self.rails
      defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application ? ::Rails : nil
    end

    # Close every connection the preloader opened so no socket is shared
    # between processes.
    def self.default_before_fork(active_record: self.active_record)
      return unless active_record

      base = active_record::Base
      return unless base.respond_to?(:connection_handler)

      handler = base.connection_handler
      return unless handler.respond_to?(:clear_all_connections!)

      if handler.method(:clear_all_connections!).arity != 0
        begin
          handler.clear_all_connections!(:all)
          return
        rescue ArgumentError, NoMethodError
          nil
        end
      end
      handler.clear_all_connections!
    end

    def self.default_after_fork(worker_number, rails: self.rails, active_record: self.active_record, simplecov: simplecov_module)
      if simplecov && simplecov.respond_to?(:running) && simplecov.running && simplecov.respond_to?(:at_fork)
        simplecov.at_fork.call(worker_number)
      end
      reestablish_active_record(rails: rails, active_record: active_record)
    end

    # Reconnect with the configuration evaluated now, with this worker's
    # TEST_ENV_NUMBER (the preloader's cached configuration names the first
    # worker's database).
    def self.reestablish_active_record(rails: self.rails, active_record: self.active_record)
      return unless rails && active_record

      base = active_record::Base
      configuration = begin
        rails.application.config.database_configuration
      rescue StandardError
        nil
      end
      base.configurations = configuration if configuration && base.respond_to?(:configurations=)
      base.establish_connection(:test)
    end

    def self.simplecov_module
      defined?(::SimpleCov) ? ::SimpleCov : nil
    end
  end

  def self.hooks
    @hooks ||= Hooks.new
  end

  def self.configure
    yield hooks if block_given?
    hooks
  end
end
