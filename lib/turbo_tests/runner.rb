# frozen_string_literal: true

require "json"
require "parallel_tests/rspec/runner"
require "parallel_tests/tasks"

require_relative "../utils/hash_extension"

module TurboTests
  class Runner
    using CoreExtensions

    def self.create(count)
      ENV["PARALLEL_TEST_FIRST_IS_1"] = "true"
      command = ["bundle", "exec", "rake", "db:create", "RAILS_ENV=#{ParallelTests::Tasks.rails_env}"]
      args = {count: count.to_s}
      ParallelTests::Tasks.run_in_parallel(command, args)
    end

    def self.run(opts = {})
      files = opts[:files]
      formatters = opts[:formatters]
      tags = opts[:tags]
      parallel_options = opts[:parallel_options] || {}

      start_time = opts.fetch(:start_time) { RSpec::Core::Time.now }
      runtime_log = opts.fetch(:runtime_log, nil)
      verbose = opts.fetch(:verbose, false)
      fail_fast = opts.fetch(:fail_fast, nil)
      count = opts.fetch(:count, nil)
      seed = opts.fetch(:seed, nil)
      seed_used = !seed.nil?
      print_failed_group = opts.fetch(:print_failed_group, false)
      nice = opts.fetch(:nice, false)

      use_runtime_info = files == ["spec"]

      if use_runtime_info
        parallel_options[:runtime_log] = runtime_log
      else
        parallel_options[:group_by] = :filesize
      end

      warn("VERBOSE") if verbose

      reporter = Reporter.from_config(formatters, start_time, seed, seed_used, files, parallel_options)

      new(
        reporter: reporter,
        formatters: formatters,
        start_time: start_time,
        files: files,
        tags: tags,
        runtime_log: runtime_log,
        verbose: verbose,
        fail_fast: fail_fast,
        count: count,
        seed: seed,
        seed_used: seed_used,
        print_failed_group: print_failed_group,
        use_runtime_info: use_runtime_info,
        parallel_options: parallel_options,
        nice: nice,
      ).run
    end

    def initialize(**opts)
      @formatters = opts[:formatters]
      @reporter = opts[:reporter]
      @files = opts[:files]
      @tags = opts[:tags]
      @verbose = opts[:verbose]
      @fail_fast = opts[:fail_fast]
      @start_time = opts[:start_time]
      @count = opts[:count]
      @seed = opts[:seed]
      @seed_used = opts[:seed_used]
      @nice = opts[:nice]
      @use_runtime_info = opts[:use_runtime_info]

      @load_time = 0
      @load_count = 0
      @failure_count = 0

      # Supports runtime_log as a top level option,
      #   but also nested inside parallel_options
      @runtime_log = opts[:runtime_log] || "tmp/turbo_rspec_runtime.log"
      @parallel_options = opts.fetch(:parallel_options, {})
      @parallel_options[:runtime_log] ||= @runtime_log
      @record_runtime = @parallel_options[:group_by] == :runtime

      @messages = Thread::Queue.new
      @threads = []
      @wait_threads = []
      @error = false
      @print_failed_group = opts[:print_failed_group]
    end

    def run
      @num_processes = [
        ParallelTests.determine_number_of_processes(@count),
        ParallelTests::RSpec::Runner.tests_with_size(@files, {}).size,
      ].min

      tests_in_groups =
        ParallelTests::RSpec::Runner.tests_in_groups(
          @files,
          @num_processes,
          **@parallel_options,
        )

      subprocess_opts = {
        record_runtime: @record_runtime,
      }

      @reporter.report(tests_in_groups) do |_reporter|
        old_signal = Signal.trap(:INT) { handle_interrupt }

        @wait_threads = tests_in_groups.map.with_index do |tests, process_id|
          start_regular_subprocess(tests, process_id + 1, **subprocess_opts)
        end.compact
        @interrupt_handled = false

        handle_messages

        @threads.each(&:join)

        report_failed_group(tests_in_groups) if @print_failed_group

        Signal.trap(:INT, old_signal)

        if @reporter.failed_examples.empty? && @wait_threads.map(&:value).all?(&:success?)
          0
        else
          # From https://github.com/serpapi/turbo_tests/pull/20/
          @wait_threads.map { |thread| thread.value.exitstatus }.max
        end
      end
    end

    private

    def handle_interrupt
      if @interrupt_handled
        Kernel.exit
      else
        puts "\nShutting down subprocesses..."
        @wait_threads.each do |wait_thr|
          child_pid = wait_thr.pid
          pgid = Process.respond_to?(:getpgid) ? Process.getpgid(child_pid) : 0
          Process.kill(:INT, child_pid) if Process.pid != pgid
        rescue Errno::ESRCH, Errno::ENOENT
        end
        @interrupt_handled = true
      end
    end

    def start_regular_subprocess(tests, process_id, **opts)
      start_subprocess(
        {"TEST_ENV_NUMBER" => process_id.to_s},
        @tags.map { |tag| "--tag=#{tag}" },
        tests,
        process_id,
        **opts,
      )
    end

    def start_subprocess(env, extra_args, tests, process_id, record_runtime:)
      if tests.empty?
        @messages << {
          type: "exit",
          process_id: process_id,
        }

        nil
      else
        env["RSPEC_FORMATTER_OUTPUT_ID"] = SecureRandom.uuid
        env["RUBYOPT"] = ["-I#{File.expand_path("..", __dir__)}", ENV["RUBYOPT"]].compact.join(" ")
        env["RSPEC_SILENCE_FILTER_ANNOUNCEMENTS"] = "1"

        command_name =
          if ENV["RSPEC_EXECUTABLE"]
            ENV["RSPEC_EXECUTABLE"].split
          elsif ENV["BUNDLE_BIN_PATH"]
            [ENV["BUNDLE_BIN_PATH"], "exec", "rspec"]
          else
            "rspec"
          end

        record_runtime_options =
          if record_runtime
            [
              "--format",
              "ParallelTests::RSpec::RuntimeLogger",
              "--out",
              @runtime_log,
            ]
          else
            []
          end

        seed_option = if @seed_used
          [
            "--seed", @seed,
          ]
        else
          []
        end

        spec_opts = ParallelTests::RSpec::Runner.send(:spec_opts)

        command = [
          *command_name,
          *extra_args,
          *seed_option,
          "--format",
          "TurboTests::JsonRowsFormatter",
          *record_runtime_options,
          *spec_opts,
          *tests,
        ]
        command.unshift("nice") if @nice

        if @verbose
          command_str = [
            env.map { |k, v| "#{k}=#{v}" }.join(" "),
            command.join(" "),
          ].select { |x| x.size > 0 }.join(" ")

          warn("Process #{process_id}: #{command_str}")
        end

        stdin, stdout, stderr, wait_thr = Open3.popen3(env, *command)
        stdin.close

        @threads <<
          Thread.new do
            stdout.each_line do |line|
              result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

              initial = result.shift
              print(initial) unless initial.empty?

              message = result.shift
              next unless message

              message = JSON.parse(message, symbolize_names: true)

              message[:process_id] = process_id
              @messages << message
            end

            @messages << {type: "exit", process_id: process_id}
          end

        @threads << start_copy_thread(stderr, STDERR)

        @threads << Thread.new do
          @messages << {type: "error"} unless wait_thr.value.success?
        end

        wait_thr
      end
    end

    def start_copy_thread(src, dst)
      Thread.new do
        loop do
          msg = src.readpartial(4096)
        rescue EOFError
          src.close
          break
        else
          dst.write(msg)
        end
      end
    end

    def handle_messages
      exited = 0

      loop do
        message = @messages.pop
        case message[:type]
        when "example_passed"
          example = FakeExample.from_obj(message[:example])
          @reporter.example_passed(example)
        when "group_started"
          @reporter.group_started(message[:group].to_struct)
        when "group_finished"
          @reporter.group_finished
        when "example_pending"
          example = FakeExample.from_obj(message[:example])
          @reporter.example_pending(example)
        when "load_summary"
          message = message[:summary]
          # NOTE: notifications order and content is not guaranteed hence the fetch
          #       and count increment tracking to get the latest accumulated load time
          @reporter.load_time = message[:load_time] if message.fetch(:count, 0) > @load_count
        when "example_failed"
          example = FakeExample.from_obj(message[:example])
          @reporter.example_failed(example)
          @failure_count += 1
          if fail_fast_met
            @threads.each(&:kill)
            break
          end
        when "message"
          if message[:message].include?("An error occurred") || message[:message].include?("occurred outside of examples")
            @reporter.error_outside_of_examples(message[:message])
            @error = true
          else
            @reporter.message(message[:message])
          end
        when "seed"
        when "close"
        when "error"
          # Do nothing
          nil
        when "exit"
          exited += 1
          break if exited == @num_processes
        else
          warn("Unhandled message in main process: #{message}")
        end

        STDOUT.flush
      end
    rescue Interrupt
    end

    def fail_fast_met
      !@fail_fast.nil? && @failure_count >= @fail_fast
    end

    def report_failed_group(tests_in_groups)
      @wait_threads.map(&:value).each_with_index do |value, index|
        next if value.success?

        failing_group = tests_in_groups[index].join(" ")
        puts "Group that failed: #{failing_group}"
      end
    end
  end
end
