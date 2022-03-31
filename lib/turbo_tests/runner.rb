# frozen_string_literal: true

require "json"
require "parallel_tests/rspec/runner"

require_relative "../utils/hash_extension"

module TurboTests
  class Runner
    using CoreExtensions

    def self.run(opts = {})
      files = opts[:files]
      formatters = opts[:formatters]
      tags = opts[:tags]

      # SEE: https://bit.ly/2NP87Cz
      start_time = opts.fetch(:start_time) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      runtime_log = opts.fetch(:runtime_log, nil)
      verbose = opts.fetch(:verbose, false)
      fail_fast = opts.fetch(:fail_fast, nil)
      count = opts.fetch(:count, nil)
      test_options = opts.fetch(:test_options, nil)

      if verbose
        STDERR.puts "VERBOSE"
      end

      reporter = Reporter.from_config(formatters, start_time)

      new(
        reporter: reporter,
        files: files,
        tags: tags,
        runtime_log: runtime_log,
        verbose: verbose,
        fail_fast: fail_fast,
        count: count,
        test_options: test_options
      ).run
    end

    def initialize(opts)
      @reporter = opts[:reporter]
      @files = opts[:files]
      @tags = opts[:tags]
      @runtime_log = opts[:runtime_log] || "tmp/turbo_rspec_runtime.log"
      @verbose = opts[:verbose]
      @fail_fast = opts[:fail_fast]
      @count = opts[:count]
      @test_options = opts[:test_options]
      @load_time = 0
      @load_count = 0
      @failure_count = 0

      @messages = Queue.new
      @threads = []
      @error = false
    end

    def run
      @num_processes = [
        ParallelTests.determine_number_of_processes(@count),
        ParallelTests::RSpec::Runner.tests_with_size(@files, {}).size
      ].min

      use_runtime_info = @files == ["spec"]

      group_opts = {}

      if use_runtime_info
        group_opts[:runtime_log] = @runtime_log
      else
        group_opts[:group_by] = :filesize
      end

      tests_in_groups =
        ParallelTests::RSpec::Runner.tests_in_groups(
          @files,
          @num_processes,
          **group_opts
        )

      setup_tmp_dir

      subprocess_opts = {
        record_runtime: use_runtime_info,
        test_options: @test_options
      }

      report_number_of_tests(tests_in_groups)

      wait_threads = tests_in_groups.map.with_index do |tests, process_id|
        start_regular_subprocess(tests, process_id + 1, **subprocess_opts)
      end

      handle_messages

      @reporter.finish

      @threads.each(&:join)

      threads = wait_threads.map(&:value)
      no_failures = @reporter.failed_examples.empty?
      failure = threads.detect { |t| !t.success? }
      return failure if failure
      true
    end

    private

    def setup_tmp_dir
      begin
        FileUtils.rm_r("tmp/test-pipes")
      rescue Errno::ENOENT
      end

      FileUtils.mkdir_p("tmp/test-pipes/")
    end

    def start_regular_subprocess(tests, process_id, **opts)
      extra_args = nil
      if test_options = opts.delete(:test_options)
        extra_args = @test_options
        extra_args << " "
      end
      if @tags.any?
        extra_args << @tags.map { |tag| "--tag=#{tag}" }&.join(" ")
      end
      start_subprocess(
        {"TEST_ENV_NUMBER" => process_id.to_s},
        # @tags.map { |tag| "--tag=#{tag}" },
        extra_args,
        tests,
        process_id,
        **opts
      )
    end

    def start_subprocess(env, extra_args, tests, process_id, record_runtime:)
      if tests.empty?
        @messages << {
          type: "exit",
          process_id: process_id
        }
      else
        tmp_filename = "tmp/test-pipes/subprocess-#{process_id}"

        begin
          File.mkfifo(tmp_filename)
        rescue Errno::EEXIST
        end

        env["RUBYOPT"] = ["-I#{File.expand_path("..", __dir__)}", ENV["RUBYOPT"]].compact.join(" ")
        env["RSPEC_SILENCE_FILTER_ANNOUNCEMENTS"] = "1"

        record_runtime_options =
          if record_runtime
            [
              "--format", "ParallelTests::RSpec::RuntimeLogger",
              "--out", @runtime_log,
            ]
          else
            []
          end

        command = [
          ENV["BUNDLE_BIN_PATH"], "exec", "rspec",
          *extra_args,
          "--seed", rand(0xFFFF).to_s,
          "--format", "TurboTests::JsonRowsFormatter",
          "--out", tmp_filename,
          *record_runtime_options,
          *tests
        ]

        if @verbose
          command_str = [
            env.map { |k, v| "#{k}=#{v}" }.join(" "),
            command.join(" ")
          ].select { |x| x.size > 0 }.join(" ")

          STDERR.puts "Process #{process_id}: #{command_str}"
        end

        stdin, stdout, stderr, wait_thr = Open3.popen3(env, *command)
        stdin.close

        @threads <<
          Thread.new do
            File.open(tmp_filename) do |fd|
              fd.each_line do |line|
                message = JSON.parse(line, symbolize_names: true)

                message[:process_id] = process_id
                @messages << message
              end
            end

            @messages << {type: "exit", process_id: process_id}
          end

        @threads << start_copy_thread(stdout, STDOUT)
        @threads << start_copy_thread(stderr, STDERR)

        @threads << Thread.new {
          unless wait_thr.value.success?
            @messages << {type: "error"}
          end
        }

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
          @reporter.message(message[:message])
        when "seed"
        when "close"
        when "error"
          @reporter.error_outside_of_examples
          @error = true
        when "exit"
          exited += 1
          if exited == @num_processes
            break
          end
        else
          STDERR.puts("Unhandled message in main process: #{message}")
        end

        STDOUT.flush
      end
    rescue Interrupt
    end

    def fail_fast_met
      !@fail_fast.nil? && @fail_fast >= @failure_count
    end

    def report_number_of_tests(groups)
      name = ParallelTests::RSpec::Runner.test_file_name

      num_processes = groups.size
      num_tests = groups.map(&:size).sum
      tests_per_process = (num_processes == 0 ? 0 : num_tests.to_f / num_processes).round

      puts "#{num_processes} processes for #{num_tests} #{name}s, ~ #{tests_per_process} #{name}s per process"
    end
  end
end
