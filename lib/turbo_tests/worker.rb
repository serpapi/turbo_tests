# frozen_string_literal: true

require "json"
require "stringio"
require "rspec/core"

require_relative "protocol"
require_relative "json_rows_formatter"
require_relative "diagnostics"
require_relative "hooks"
require_relative "env_number"

module TurboTests
  # The child side of the spawn and fork pools. One long-lived RSpec process
  # that runs one job (a few spec files) at a time:
  #
  #   ready -> {job} -> rows... seed, job_finished -> ready -> ... {shutdown} -> exit
  #
  # before(:suite) hooks run once per worker (first job) and after(:suite)
  # hooks once on shutdown, like one `rspec` run per process. Between jobs
  # examples, the world and the reporter are reset while the configuration
  # (spec_helper settings, filters, hooks) is kept.
  class Worker
    FORMATTER = "TurboTests::JsonRowsFormatter"
    BEFORE_SUITE = "a `before(:suite)` hook"

    @own_frames_hidden = false

    def self.main(env = ENV)
      exit(new(env).run)
    end

    # Process-wide settings shared by spawned workers and the preloader.
    def self.base_args(env = ENV)
      JSON.parse(env["TURBO_TESTS_RSPEC_ARGS"] || "[]")
    end

    # Loads what `rspec` loads before spec files (`--require spec_helper`
    # from .rspec), or `preload` instead of those requires. The rows
    # formatter is registered first, so errors while requiring become rows.
    def self.configure_base(args, preload = nil)
      config = RSpec.configuration
      config.add_formatter(TurboTests::JsonRowsFormatter)
      options = RSpec::Core::ConfigurationOptions.new(args + ["--format", FORMATTER])
      options.options.delete(:requires) if preload
      options.configure(config)
      require File.expand_path(preload) if preload && !RSpec.world.wants_to_quit
    end

    # Shares the parent's seed without forcing random order: a no-op for the
    # ordering when it is `defined`, and skipped when the user chose a seed
    # (--seed, --order rand:N, config.seed = N).
    def self.apply_seed(seed, initial_seed)
      return if seed.nil?

      config = RSpec.configuration
      return unless config.respond_to?(:ordering_manager)
      return unless config.seed == initial_seed

      manager = config.ordering_manager
      global = manager.ordering_registry.fetch(:global)
      manager.seed = seed
      manager.register_ordering(:global, global)
    end

    def self.config_row(silence_filter_announcements)
      config = RSpec.configuration
      profile = config.profile_examples
      {
        type: "config",
        order: order_name(config),
        seed: config.seed,
        profile_examples: profile.is_a?(Integer) ? profile : nil,
        example_status_persistence_file_path: config.example_status_persistence_file_path,
        fail_fast: config.fail_fast,
        silence_filter_announcements: silence_filter_announcements ? true : false,
        fail_if_no_examples: config.fail_if_no_examples ? true : false,
        failure_exit_code: config.failure_exit_code,
        error_exit_code: config.respond_to?(:error_exit_code) ? config.error_exit_code : nil
      }
    end

    def self.order_name(config)
      strategy = config.ordering_registry.fetch(:global)
      ordering = RSpec::Core::Ordering
      return "random" if strategy.is_a?(ordering::Random)
      return "defined" if strategy.is_a?(ordering::Identity)
      return "recently-modified" if ordering.const_defined?(:RecentlyModified) && strategy.is_a?(ordering::RecentlyModified)

      "custom"
    rescue StandardError
      nil
    end

    OWN_LIB = File.expand_path("..", __dir__)

    # Keeps turbo_tests' own frames out of failure output when its lib/ is
    # one of the project's source dirs (running from a checkout of this gem,
    # or vendored): RSpec would otherwise quote a turbo_tests line as the
    # "Failure/Error" of errors raised while loading spec files.
    def self.hide_own_frames(config = RSpec.configuration)
      return if @own_frames_hidden

      @own_frames_hidden = true
      config.backtrace_exclusion_patterns << %r{\A#{Regexp.escape(OWN_LIB)}/turbo_tests/(?:worker|preloader)\.rb:}
      config.backtrace_exclusion_patterns << /\A-e:\d+/
      dirs = config.project_source_dirs
      return unless dirs.any? { |dir| File.expand_path(dir) == OWN_LIB }

      others = Dir.glob(File.join(OWN_LIB, "*")).select do |path|
        File.directory?(path) && File.basename(path) != "turbo_tests"
      end
      config.project_source_dirs = dirs.reject { |dir| File.expand_path(dir) == OWN_LIB } + others
    end

    def self.nice(env = ENV)
      return unless env["TURBO_TESTS_NICE"] == "1"

      Process.setpriority(Process::PRIO_PROCESS, 0, 19)
    rescue StandardError, NotImplementedError
      nil
    end

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def initialize(env = ENV, booted: false)
      @env = env
      @index = Integer(env["TURBO_TESTS_WORKER"] || "1")
      @booted = booted
      @verbose = env["TURBO_TESTS_VERBOSE"] == "1"
      timeout = env["TURBO_TESTS_EXIT_TIMEOUT"].to_s
      @exit_timeout = timeout =~ /\A\d+(\.\d+)?\z/ ? timeout.to_f : 60.0
      @seed = env["TURBO_TESTS_SEED"].to_s =~ /\A\d+\z/ ? env["TURBO_TESTS_SEED"].to_i : nil
      @deprecation_sink = nil
      @ran_before_suite_hooks = []
      @suite_hooks_failed = false
      @warned_hooks = false
      @options_args = nil
      @options = nil
      @options_files = nil
      @finished_rows = nil
      @runner = nil
      @rows = nil
      @job_started = nil
      @watchdog = nil
    end

    # The exit status of the process. A parent that went away (closed our
    # pipes) ends the worker quietly.
    def run
      serve
    rescue Errno::EPIPE
      1
    end

    def serve
      $stdout.sync = true
      $stderr.sync = true
      @rows = Protocol.default_writer($stdout)
      RSpec::Core::Runner.trap_interrupt if RSpec::Core::Runner.respond_to?(:trap_interrupt)
      RSpec::Core::Runner.disable_autorun! if RSpec::Core::Runner.respond_to?(:disable_autorun!)
      Worker.hide_own_frames
      return 1 unless @booted || boot

      write_ready
      job = read_job
      status = job ? run_jobs(job) : 0
      write(type: "exit", worker: @index, pid: Process.pid)
      status
    end

    private

    # Spawned workers load what `rspec` would load before the spec files
    # (`--require spec_helper` from .rspec), then the first one reports the
    # configuration and probes TEST_ENV_NUMBER when asked to.
    def boot
      Worker.nice(@env)
      Hooks.load_project_file
      initial_seed = RSpec.configuration.seed
      Worker.configure_base(Worker.base_args(@env))
      silence = RSpec.configuration.silence_filter_announcements
      if RSpec.world.wants_to_quit
        write(type: "error", worker: @index, message: "Worker #{@index} could not load the files required by the RSpec options.",
          reported: true)
        return false
      end
      Worker.apply_seed(@seed, initial_seed)
      write(Worker.config_row(silence)) if @index == 1
      probe_env_number if @env["TURBO_TESTS_PROBE"] == "1"
      true
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise if e.is_a?(SystemExit) || e.is_a?(Interrupt)

      write(type: "error", worker: @index, message: "#{e.class}: #{e.message}", backtrace: e.backtrace)
      false
    end

    def probe_env_number
      value = EnvNumber.probe
      write(type: "env_number", value: value, probed: true)
      return unless value == "1"

      ENV["TEST_ENV_NUMBER"] = "1"
      Hooks.reestablish_active_record
    rescue EnvNumber::Ambiguous => e
      write(type: "error", worker: @index, message: e.message)
      raise SystemExit.new(1)
    end

    def run_jobs(first_job)
      config = RSpec.configuration
      cleanup
      prepare(first_job)
      before = RSpec.world.wants_to_quit
      config.with_suite_hooks do
        @suite_hooks_failed = !before && RSpec.world.wants_to_quit
        @ran_before_suite_hooks = (before_suite_hooks || []).dup
        warn_unknown_hooks if before_suite_hooks.nil?
        job = first_job
        loop do
          execute(job)
          report_gc_stat
          write_ready
          job = read_job
          break unless job

          prepare(job)
          run_late_before_suite_hooks(job)
        end
        @watchdog = Diagnostics.start_exit_watchdog(@exit_timeout, "worker #{@index} (pid #{Process.pid})")
        prepare_after_suite_reporting
      end
      return 0 unless RSpec.world.non_example_failure

      config.respond_to?(:error_exit_code) && config.error_exit_code || config.failure_exit_code || 1
    end

    def prepare(job)
      @job_started = Worker.monotonic
      world = RSpec.world
      config = RSpec.configuration
      world.wants_to_quit = false
      world.non_example_failure = false if world.respond_to?(:non_example_failure=)
      world.rspec_is_quitting = false if world.respond_to?(:rspec_is_quitting=)

      redirect_deprecations(config)
      @runner = RSpec::Core::Runner.new(configuration_options(Array(job[:args]), Array(job[:files])))
      load_path_size = $LOAD_PATH.size
      begin
        # Registered before the options' requires run, so their errors are rows.
        config.add_formatter(TurboTests::JsonRowsFormatter)
        @runner.configure($stderr, $stdout)
        $LOAD_PATH.uniq! if $LOAD_PATH.size > load_path_size
        silence_deprecation_formatter(config)
        config.load_spec_files unless world.wants_to_quit
      ensure
        config.silence_filter_announcements = true
        world.announce_filters
      end
      world.wants_to_quit = true if @suite_hooks_failed
    end

    def execute(job)
      config = RSpec.configuration
      world = RSpec.world
      count = 0
      # Ordered even when the job stops early (load error): with random
      # ordering configured the seed counts as used, so it is reported.
      groups = world.ordered_example_groups
      exit_code =
        if world.wants_to_quit
          config.reporter.exit_early(runner_exit_code(false))
        else
          count = world.example_count(groups)
          passed = config.reporter.report(count) do |reporter|
            groups.map { |group| group.run(reporter) }.all?
          end
          runner_exit_code(passed)
        end
      persist_example_statuses
      @finished_rows = [
        {type: "seed", seed: config.seed, seed_used: config.seed_used? ? true : false, worker: @index},
        {
          type: "job_finished",
          job_id: job[:id],
          exit_code: exit_code,
          duration: Worker.monotonic - @job_started,
          files: job[:files],
          example_count: count,
          worker: @index
        }
      ]
    ensure
      cleanup
    end

    # Every job carries the same RSpec arguments: parse them (and the option
    # files they pull in: .rspec, .rspec-local, ~/.rspec, SPEC_OPTS) once and
    # only swap the files to run.
    def configuration_options(args, files)
      unless @options_args == args
        @options_args = args
        @options = RSpec::Core::ConfigurationOptions.new(args)
        @options_files = @options.options[:files_or_directories_to_run] || []
      end
      @options.options[:files_or_directories_to_run] = @options_files + files
      @options
    end

    def runner_exit_code(passed)
      return @runner.exit_code(passed) if @runner.respond_to?(:exit_code)

      passed ? 0 : RSpec.configuration.failure_exit_code
    end

    def persist_example_statuses
      @runner.__send__(:persist_example_statuses) if @runner.respond_to?(:persist_example_statuses, true)
    end

    def cleanup
      RSpec.clear_examples
      RSpec.configuration.reset
      world = RSpec.world
      world.prepare_example_filtering if world.respond_to?(:prepare_example_filtering)
      prune_shared_example_groups(world)
    end

    # `shared_examples` declared inside an example group are registered under
    # that group's class; `world.reset` removes the class but not the entry,
    # so every such group would stay reachable for the life of the worker.
    # Top-level registrations (:main) are kept: support files define them once.
    def prune_shared_example_groups(world)
      return unless world.respond_to?(:shared_example_group_registry)

      registry = world.shared_example_group_registry
      return unless registry.instance_variable_defined?(:@shared_example_groups)

      registry.instance_variable_get(:@shared_example_groups).delete_if do |context, _|
        context.is_a?(Class) && context < RSpec::Core::ExampleGroup
      end
    end

    # Leak diagnostics for bin/leak_check: with TURBO_TESTS_GC_STAT_EVERY=N a
    # full GC runs every N jobs and live-object counts go to stderr, so RSS
    # growth can be told apart from retained objects.
    def report_gc_stat
      every = @env["TURBO_TESTS_GC_STAT_EVERY"].to_i
      return unless every > 0

      @jobs_done = (@jobs_done || 0) + 1
      return unless (@jobs_done % every).zero?

      GC.start
      stat = GC.stat
      $stderr.puts("gc_stat worker=#{@index} jobs=#{@jobs_done} heap_live_slots=#{stat[:heap_live_slots]} " \
                   "old_objects=#{stat[:old_objects]} malloc_increase_bytes=#{stat[:malloc_increase_bytes]} " \
                   "total_allocated_objects=#{stat[:total_allocated_objects]}")
      $stderr.flush
    end

    # Workers' deprecations travel as rows and are printed once by the parent;
    # unless the user chose a deprecation stream, the per-worker copies go to
    # a sink (DeprecationFormatter would also print "N deprecation warnings
    # total" to stdout).
    def redirect_deprecations(config)
      stream = config.deprecation_stream
      if stream.equal?($stderr) || stream.equal?(STDERR)
        @deprecation_sink ||= StringIO.new
        config.deprecation_stream = @deprecation_sink
      end
      return unless @deprecation_sink

      @deprecation_sink.truncate(0)
      @deprecation_sink.rewind
    end

    def silence_deprecation_formatter(config)
      return unless @deprecation_sink && config.deprecation_stream.equal?(@deprecation_sink)

      config.add_formatter(RSpec::Core::Formatters::DeprecationFormatter.new(@deprecation_sink, @deprecation_sink))
    end

    def prepare_after_suite_reporting
      config = RSpec.configuration
      world = RSpec.world
      world.non_example_failure = false if world.respond_to?(:non_example_failure=)
      redirect_deprecations(config)
      config.add_formatter(TurboTests::JsonRowsFormatter)
      silence_deprecation_formatter(config)
    end

    def before_suite_hooks
      config = RSpec.configuration
      return nil unless config.instance_variable_defined?(:@before_suite_hooks)

      hooks = config.instance_variable_get(:@before_suite_hooks)
      hooks.is_a?(Array) ? hooks : nil
    end

    # A file loaded by a later job may register before(:suite) hooks; they
    # never ran in this worker, so run them now.
    def run_late_before_suite_hooks(job)
      hooks = before_suite_hooks
      return warn_unknown_hooks if hooks.nil?

      fresh = hooks.reject { |hook| @ran_before_suite_hooks.any? { |ran| ran.equal?(hook) } }
      return if fresh.empty?

      @ran_before_suite_hooks = hooks.dup
      if @verbose
        warn "turbo_tests: worker #{@index} runs #{fresh.size} before(:suite) hook(s) registered while loading #{Array(job[:files]).join(" ")}"
      end
      config = RSpec.configuration
      return unless config.respond_to?(:run_suite_hooks, true)

      quitting = RSpec.world.wants_to_quit
      previous = RSpec.respond_to?(:current_scope) ? RSpec.current_scope : nil
      RSpec.current_scope = :before_suite_hook if RSpec.respond_to?(:current_scope=)
      config.__send__(:run_suite_hooks, BEFORE_SUITE, fresh)
      RSpec.current_scope = previous if previous && RSpec.respond_to?(:current_scope=)
      @suite_hooks_failed = true if RSpec.world.wants_to_quit && !quitting
    end

    def warn_unknown_hooks
      return if @warned_hooks

      @warned_hooks = true
      warn "turbo_tests: cannot see RSpec's before(:suite) hooks (rspec-core #{RSpec::Core::Version::STRING}); " \
        "hooks registered by spec files loaded in later jobs will not run"
      nil
    end

    def read_job
      line = $stdin.gets
      return nil unless line

      row = Protocol.decode(line)
      row && row[:type] == "job" ? row : nil
    rescue IOError, SystemCallError
      nil
    end

    # The rows ending a job go out in one write with `ready`: one wakeup of
    # the parent instead of three before it can hand out the next job.
    def write_ready
      rows = (@finished_rows || []) + [{type: "ready", worker: @index, pid: Process.pid, test_env_number: ENV["TEST_ENV_NUMBER"]}]
      @finished_rows = nil
      @rows.write_all(rows)
    end

    def write(row)
      @rows.write(row)
    end
  end
end
