# frozen_string_literal: true

module TurboTests
  # Everything a run needs to know, built by the CLI (or from the v2 hash API).
  class Options
    POOLS = [:auto, :fork, :spawn, :command].freeze
    GROUP_BY = [:runtime, :filesize, :found].freeze
    DEFAULT_EXIT_TIMEOUT = 60.0

    attr_accessor :workers, :files, :rspec_args, :formatters, :requires, :tags, :seed, :order,
      :fail_fast, :pattern, :exclude_pattern, :default_path, :group_by, :only_group, :groups,
      :runtime_log, :record_runtime, :first_is_1, :nice, :preload, :pool, :static, :exit_timeout,
      :diagnose, :print_failed_group, :profile, :only_failures, :next_failure, :verbose,
      :rake_hooks, :test_options, :start_time

    def initialize(attributes = {})
      @workers = nil
      @files = []
      @rspec_args = []
      @formatters = []
      @requires = []
      @tags = []
      @seed = nil
      @order = nil
      @fail_fast = nil
      @pattern = nil
      @exclude_pattern = nil
      @default_path = nil
      @group_by = :runtime
      @only_group = []
      @groups = nil
      @runtime_log = nil
      @record_runtime = nil
      @first_is_1 = nil
      @nice = false
      @preload = nil
      @pool = :auto
      @static = false
      @exit_timeout = DEFAULT_EXIT_TIMEOUT
      @diagnose = false
      @print_failed_group = false
      @profile = nil
      @only_failures = false
      @next_failure = false
      @verbose = false
      @rake_hooks = true
      @test_options = nil
      @start_time = nil

      attributes.each { |name, value| public_send("#{name}=", value) }
    end

    # Maps the keyword hash accepted by TurboTests::Runner.run in 2.x
    # (formatters:, tags:, files:, runtime_log:, verbose:, fail_fast:, count:,
    # seed:, start_time:) onto Options.
    def self.from_hash(hash)
      options = new
      hash.each do |key, value|
        case key.to_sym
        when :count, :workers, :n
          options.workers = value
        when :files
          options.files = Array(value)
        when :formatters
          options.formatters = value || []
        when :tags
          options.tags = value || []
        when :seed
          options.seed = value.nil? ? nil : value.to_s
        else
          setter = "#{key}="
          if options.respond_to?(setter)
            options.public_send(setter, value)
          else
            warn "turbo_tests: ignoring unknown option #{key.inspect}"
          end
        end
      end
      options
    end

    def seed_forced?
      !seed.nil? || random_order?
    end

    def random_order?
      !order.nil? && order.to_s.include?("rand")
    end

    def unbounded_exit?
      exit_timeout.nil? || exit_timeout.to_f <= 0
    end
  end
end
