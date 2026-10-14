# frozen_string_literal: true

require "json"
require "etc"

module TurboTests
  # Glue: Files -> RuntimeLog -> Scheduler -> Pool -> Supervisor -> exit status.
  class Runner
    BUILT_IN_FORMATTERS = %w[p progress d doc documentation j json f failures].freeze

    # Accepts Options or the 2.x keyword hash (formatters:, tags:, files:,
    # runtime_log:, verbose:, fail_fast:, count:, seed:, start_time:).
    def self.run(opts = {})
      options = opts.is_a?(Options) ? opts : Options.from_hash(opts)
      new(options).run
    end

    def initialize(options, out: $stdout, err: $stderr)
      @options = options
      @out = out
      @err = err
      @options.start_time ||= RSpec::Core::Time.now
      @options.workers ||= default_workers
      @options.formatters = [{name: "progress", outputs: ["-"]}] if @options.formatters.nil? || @options.formatters.empty?
    end

    def run
      rspec_options = Files.rspec_options(@options.rspec_args)
      entries = Files.resolve(@options)
      @seed = pick_seed(rspec_options)
      @pool_name = Pool.resolve(@options)
      @job_args = job_args(rspec_options)

      reporter = Reporter.from_config(@options.formatters, @options.start_time, @seed, @options.seed_forced?)
      configure_reporter(reporter)

      _runtime_path, runtimes = RuntimeLog.load_first(RuntimeLog.candidates(@options))
      scheduler = build_scheduler(entries, runtimes)
      workers = [@options.workers.to_i, scheduler.size].min
      return run_without_workers(reporter, scheduler) if workers < 1

      pool = Pool.class_for(@pool_name).new(@options, workers: workers, env_base: env_base)
      pool.first_env_number = EnvNumber.forced(@options.first_is_1) || (@pool_name == :command ? "" : nil)
      supervisor = Supervisor.new(pool, scheduler, reporter, @options, job_args: @job_args, out: @out, err: @err)
      begin
        supervisor.boot(wait_for_config: @options.only_failures && @pool_name != :command)
        if @options.only_failures && @pool_name != :command && !supervisor.aborted?
          scheduler = only_failures(entries, runtimes, supervisor.config_row, scheduler)
          supervisor.scheduler = scheduler
        end
      rescue Exception # rubocop:disable Lint/RescueException
        supervisor.emergency_stop
        raise
      end

      info = {
        workers: workers,
        pool: @pool_name.to_s,
        files: scheduler.entries_count,
        test_env_numbers: supervisor.test_env_numbers || EnvNumber.numbers("", workers),
        tags: @options.tags,
        example_count: expected_example_count(scheduler)
      }
      status = reporter.report(info) { supervisor.run }
      save_runtimes(supervisor.runtimes)
      persist_example_statuses(reporter, supervisor.config_row, supervisor.unknown_example_ids)
      status
    end

    private

    def default_workers
      from_env = ENV["PARALLEL_TEST_PROCESSORS"].to_s
      return from_env.to_i if from_env =~ /\A\s*\d+\s*\z/ && from_env.to_i > 0

      Etc.nprocessors
    end

    def configure_reporter(reporter)
      reporter.run_options = @options.tags if reporter.respond_to?(:run_options=)
      reporter.profile_examples = @options.profile if @options.profile && reporter.respond_to?(:profile_examples=)
      reporter.fail_fast = @options.fail_fast if @options.fail_fast && reporter.respond_to?(:fail_fast=)
    end

    # The parent's seed is shared by every worker (TURBO_TESTS_SEED) and only
    # forces random order when the user asked for it (--seed / --order rand).
    def pick_seed(rspec_options)
      return Integer(@options.seed) if @options.seed

      [@options.order, rspec_options[:order]].each do |order|
        match = /rand(?:om)?:(\d+)/.match(order.to_s)
        return match[1].to_i if match
      end
      rand(0xFFFF)
    end

    def job_args(rspec_options)
      args = @options.rspec_args.dup
      @options.tags.each { |tag| args.push("--tag", tag) }
      if @options.order
        args.push("--order", @options.random_order? ? "rand:#{@seed}" : @options.order)
      end
      args.push("--seed", @seed.to_s) if @options.seed
      if @pool_name == :command && !@options.seed_forced? && rspec_options[:order].to_s =~ /\Arand(?:om)?\z/
        args.push("--seed", @seed.to_s)
      end
      args.push("--profile", @options.profile.to_s) if @options.profile
      args.push("--only-failures") if @options.only_failures
      args.push("--format", Worker::FORMATTER)
      args
    end

    def env_base
      {
        "TURBO_TESTS_SEED" => @seed.to_s,
        "TURBO_TESTS_EXIT_TIMEOUT" => @options.exit_timeout.to_f.to_s,
        "TURBO_TESTS_RSPEC_ARGS" => JSON.generate(@job_args),
        "TURBO_TESTS_VERBOSE" => @options.verbose ? "1" : nil,
        "TURBO_TESTS_NICE" => @options.nice ? "1" : nil,
        "TURBO_TESTS_PROBE" => nil,
        "TURBO_TESTS_PRELOAD" => nil,
        "TURBO_TESTS_FIRST_ENV_NUMBER" => nil,
        "TURBO_TESTS_CONTROL_FD" => nil,
        "TURBO_TESTS_PIPES" => nil,
        "TURBO_TESTS_EXIT_WATCHDOG" => nil,
        "RUBYOPT" => rubyopt
      }
    end

    def rubyopt
      opt = ENV["RUBYOPT"].to_s
      if defined?(::Bundler) && ENV["BUNDLE_GEMFILE"] && opt !~ %r{bundler/setup}
        opt = "-rbundler/setup #{opt}".strip
      end
      opt.empty? ? nil : opt
    end

    def build_scheduler(entries, runtimes)
      mode = @options.static || !@options.only_group.empty? || @pool_name == :command ? :static : :dynamic
      validate_only_group
      scheduler = Scheduler.new(entries, runtimes,
        workers: @options.workers, mode: mode, groups: @options.groups, only_group: @options.only_group,
        group_by: @options.group_by)
      return scheduler unless @pool_name == :command && !@options.only_group.empty?

      # One rspec process per group: re-split the selected files.
      Scheduler.new(scheduler.files.map { |file| [file] }, runtimes,
        workers: @options.workers, mode: :static, group_by: @options.group_by)
    end

    def validate_only_group
      groups = @options.groups || @options.workers
      if @pool_name == :command && @options.groups && @options.only_group.empty? && @options.groups > @options.workers.to_i
        raise Error, "--pool command runs one rspec process per group and cannot run #{@options.groups} groups " \
                     "on #{@options.workers} workers; use --groups #{@options.workers} or another pool"
      end
      return if @options.only_group.empty?

      invalid = @options.only_group.select { |group| group > groups }
      return if invalid.empty?

      raise Error, "--only-group #{invalid.join(",")} is out of range: there are #{groups} groups (see --groups)"
    end

    # Files without a failure recorded in the persistence file are skipped
    # in the parent: rspec's own --only-failures would run every example of
    # a file it is handed when none of them failed.
    def only_failures(entries, runtimes, config_row, scheduler)
      path = config_row && config_row[:example_status_persistence_file_path]
      unless path
        @err.puts "turbo_tests: --only-failures needs config.example_status_persistence_file_path; running every file"
        return scheduler
      end

      failed = failed_files(path)
      selected = entries.select { |entry| failed.include?(RuntimeLog.normalize(Files.path_of(entry.first))) }
      build_scheduler(selected, runtimes)
    end

    def failed_files(path)
      return [] unless File.file?(path)

      RSpec::Core::ExampleStatusPersister.load_from(path).select { |row| row[:status].to_s == "failed" }.map do |row|
        RuntimeLog.normalize(row[:example_id].to_s.sub(/\[[\d:,\s]*\]\z/, ""))
      end.uniq
    rescue SystemCallError, IOError => e
      @err.puts "turbo_tests: could not read #{path}: #{e.message}"
      []
    end

    def expected_example_count(scheduler)
      custom = @options.formatters.any? { |formatter| !BUILT_IN_FORMATTERS.include?(formatter[:name].to_s) }
      return nil unless custom && Reporter.respond_to?(:count_examples)

      Reporter.count_examples(scheduler.files, @job_args)
    end

    def run_without_workers(reporter, scheduler)
      info = {workers: 0, pool: @pool_name.to_s, files: scheduler.entries_count, test_env_numbers: [], tags: @options.tags,
              example_count: 0}
      reporter.report(info) { nil }
      success = reporter.respond_to?(:success?) ? reporter.success? : reporter.failed_examples.empty?
      success ? 0 : 1
    end

    def save_runtimes(runtimes)
      return if @options.record_runtime == false || runtimes.empty?

      RuntimeLog.save(RuntimeLog.save_path(@options), runtimes)
    end

    # One write of config.example_status_persistence_file_path per run, from
    # the parent, with rspec's own merge: examples that did not run keep their
    # previous status. rspec rewrites the whole file under an exclusive lock
    # at the end of each process; doing that once per job would be quadratic
    # in the number of examples and would serialise the workers on the lock
    # (1.1 s per write at 127k recorded examples). Command-pool workers are
    # plain rspec processes and write the file themselves.
    def persist_example_statuses(reporter, config_row, unknown_example_ids = [])
      return if @pool_name == :command || config_row.nil? || config_row[:dry_run]

      path = config_row[:example_status_persistence_file_path]
      return if path.nil? || path.to_s.empty?

      # Unknown first: an id that also has a result keeps the result.
      examples = unknown_example_ids.map { |id| UnknownExample.new(id, UnknownResult.new(nil, nil)) }
      examples.concat(reporter.examples.select(&:id))
      return if examples.empty?

      RSpec::Core::ExampleStatusPersister.persist(examples, path)
    rescue SystemCallError, IOError => e
      @err.puts "turbo_tests: could not write example statuses to #{path} " \
                "(config.example_status_persistence_file_path): #{e.class}: #{e.message}"
    end

    # Stand-ins for loaded examples that did not run: rspec records them with
    # status "unknown" so the merge keeps their previous status.
    UnknownResult = Struct.new(:status, :run_time)
    UnknownExample = Struct.new(:id, :execution_result)
  end
end
