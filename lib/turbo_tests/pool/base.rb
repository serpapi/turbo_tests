# frozen_string_literal: true

require "json"
require "rbconfig"
require "securerandom"

module TurboTests
  module Pool
    LIB = File.expand_path("../..", __dir__)

    def self.windows?
      RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/ ? true : false
    end

    def self.mri?
      !defined?(RUBY_ENGINE) || RUBY_ENGINE == "ruby"
    end

    def self.fork_supported?
      mri? && !windows? && Process.respond_to?(:fork)
    end

    # Workers get their own process group only when we are not attached to
    # a terminal: in a terminal they share the foreground group so Ctrl-C
    # reaches them exactly once and debuggers keep working.
    def self.own_process_groups?(stdin = $stdin)
      return false if windows?

      !stdin.tty?
    rescue IOError
      true
    end

    def self.resolve(options)
      pool = (options.pool || :auto).to_sym
      return pool unless pool == :auto
      return :command if ENV["RSPEC_EXECUTABLE"] && !ENV["RSPEC_EXECUTABLE"].strip.empty?

      fork_supported? ? :fork : :spawn
    end

    def self.class_for(name)
      case name
      when :fork then Fork
      when :command then Command
      else Spawn
      end
    end

    # The parent's view of one worker process.
    class WorkerHandle
      attr_accessor :id, :pid, :pgid, :rows_io, :out_io, :jobs_io, :prefix, :test_env_number,
        :command, :env, :launched

      def initialize(id)
        @id = id
        @launched = false
      end
    end

    # Exit information of a reaped process.
    class ExitInfo
      attr_reader :exitstatus, :termsig

      def self.from_status(status)
        new(status.exitstatus, status.termsig)
      end

      def initialize(exitstatus, termsig)
        @exitstatus = exitstatus
        @termsig = termsig
      end

      def success?
        exitstatus == 0 && termsig.nil?
      end

      def to_s
        return exitstatus.to_s unless termsig

        name = begin
          Signal.signame(termsig)
        rescue ArgumentError
          nil
        end
        name ? "SIG#{name}" : "signal #{termsig}"
      end
    end

    class Base
      attr_reader :workers, :options
      attr_accessor :first_env_number

      # Contract entry point: builds and starts the pool.
      def self.start(options, workers:, env_base:)
        pool = new(options, workers: workers, env_base: env_base)
        pool.start
        pool
      end

      def initialize(options, workers:, env_base:)
        @options = options
        @count = workers
        @env_base = env_base
        @own_groups = Pool.own_process_groups?
        @workers = (1..workers).map { |id| WorkerHandle.new(id) }
        @children = {}
        @first_env_number = nil
      end

      def name
        self.class.name.split("::").last.downcase
      end

      def control_io
        nil
      end

      def own_process_groups?
        @own_groups
      end

      def dedicated_rows?
        !Pool.windows?
      end

      def test_env_numbers
        return nil if @first_env_number.nil?

        EnvNumber.numbers(@first_env_number, @count)
      end

      def number_for(handle)
        handle.id == 1 ? @first_env_number.to_s : handle.id.to_s
      end

      def launch_remaining
        nil
      end

      # Direct children that exited since the last call: [[handle, ExitInfo]].
      def reap
        exited = []
        @children.keys.each do |pid|
          result = begin
            Process.wait2(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            [pid, nil]
          end
          next unless result

          handle = @children.delete(pid)
          exited << [handle, result[1] ? ExitInfo.from_status(result[1]) : ExitInfo.new(nil, nil)]
        end
        exited
      end

      alias_method :poll_exits, :reap

      def children?
        !@children.empty?
      end

      def signal(handle, signal)
        pid = handle.pid
        return false unless pid

        if Pool.windows?
          Process.kill("KILL", pid)
        elsif handle.pgid && @own_groups && signal != "INT"
          # TERM/KILL take the worker's helpers (servers, browsers) with it.
          # INT is meant for RSpec alone: it stops after the current example,
          # and a helper interrupted mid-example would fail that example.
          Process.kill(signal, -handle.pgid)
        else
          Process.kill(signal, pid)
        end
        true
      rescue Errno::ESRCH, Errno::EPERM, RangeError
        false
      end

      def kill(handle, signal)
        signal(handle, signal)
      end

      def signal_all(signal)
        @workers.each { |handle| signal(handle, signal) if handle.pid }
      end

      # Process groups exist only while a member is alive, so their ids cannot
      # be reused by unrelated processes while we signal them.
      def kill_group(pgid, signal = "TERM")
        return false unless pgid && @own_groups

        Process.kill(signal, -pgid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def close
        @workers.each do |handle|
          [handle.jobs_io, handle.rows_io, handle.out_io].each { |io| close_io(io) }
        end
      end

      def close_io(io)
        io.close if io && !io.closed?
      rescue IOError, SystemCallError
        nil
      end

      def verbose_lines
        @workers.select(&:command).map do |handle|
          env = (handle.env || {}).select { |key, value| value && VERBOSE_ENV.include?(key) }
          ["Process #{handle.id}:", env.map { |k, v| "#{k}=#{v}" }.join(" "), handle.command.join(" ")]
            .reject(&:empty?).join(" ")
        end
      end

      VERBOSE_ENV = %w[TEST_ENV_NUMBER TURBO_TESTS_WORKER TURBO_TESTS_SEED RSPEC_FORMATTER_OUTPUT_ID].freeze

      private

      def worker_env(handle, number)
        env = @env_base.dup
        env["TEST_ENV_NUMBER"] = number
        env["TURBO_TESTS_WORKER"] = handle.id.to_s
        env
      end

      def spawn_options(stdin, stdout)
        opts = {in: stdin, out: stdout, err: :err}
        opts[:pgroup] = true if @own_groups
        opts
      end

      def register(handle, pid)
        handle.pid = pid
        handle.pgid = @own_groups ? pid : nil
        handle.launched = true
        @children[pid] = handle
      end

      def pipe
        reader, writer = IO.pipe
        reader.binmode
        writer.binmode
        [reader, writer]
      end
    end
  end
end
