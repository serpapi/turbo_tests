# frozen_string_literal: true

require "rbconfig"

require_relative "base"

module TurboTests
  module Pool
    # One preloader child boots the application once, then forks the
    # workers. The parent owns every pipe: the preloader inherits all of them
    # (mapped to fixed descriptors), each forked worker keeps its own three
    # and closes the rest. Workers are the parent's grandchildren, so their
    # exits are reported by the preloader on the control pipe.
    class Fork < Base
      COMMAND = [RbConfig.ruby, "-I", LIB, "-r", "turbo_tests/preloader", "-e", "TurboTests::Preloader.main"].freeze
      PRELOADER = :preloader

      attr_reader :control_io, :preloader_pid, :preloader_pgid

      def initialize(options, workers:, env_base:)
        super
        @control_io = nil
        @preloader_pid = nil
        @preloader_pgid = nil
        @preloader_env = nil
      end

      def start
        control_r, control_w = pipe
        # Only the parent holds the write end of this pipe and never writes:
        # EOF tells the preloader the parent is gone.
        alive_r, @alive_w = pipe
        fd_map = {3 => control_w, 4 => alive_r}
        child_ends = [control_w, alive_r]
        layout = []
        next_fd = 5
        @workers.each do |handle|
          jobs_r, jobs_w = pipe
          rows_r, rows_w = pipe
          out_r, out_w = pipe
          fd_map[next_fd] = jobs_r
          fd_map[next_fd + 1] = rows_w
          fd_map[next_fd + 2] = out_w
          layout << [next_fd, next_fd + 1, next_fd + 2].join(",")
          next_fd += 3
          child_ends.concat([jobs_r, rows_w, out_w])
          jobs_w.sync = true
          handle.jobs_io = jobs_w
          handle.rows_io = rows_r
          handle.out_io = out_r
          handle.command = ["(forked by preloader)"]
        end

        env = @env_base.dup
        env["TEST_ENV_NUMBER"] = @first_env_number.to_s
        env["TURBO_TESTS_WORKER"] = nil
        env["TURBO_TESTS_CONTROL_FD"] = "3"
        env["TURBO_TESTS_PARENT_FD"] = "4"
        env["TURBO_TESTS_PIPES"] = layout.join(";")
        env["TURBO_TESTS_FIRST_ENV_NUMBER"] = @first_env_number
        env["TURBO_TESTS_PROBE"] = @first_env_number.nil? ? "1" : nil
        env["TURBO_TESTS_PRELOAD"] = @options.preload
        env[Protocol::ROWS_FD_ENV] = nil
        env[Protocol::PREFIX_ENV] = nil
        if RbConfig::CONFIG["host_os"] =~ /darwin/ && !ENV.key?("OBJC_DISABLE_INITIALIZE_FORK_SAFETY")
          env["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] = "YES"
        end
        @preloader_env = env

        opts = {in: File::NULL, out: :out, err: :err}
        opts[:pgroup] = true if @own_groups
        opts.update(fd_map)
        begin
          @preloader_pid = Process.spawn(env, *COMMAND, opts)
        ensure
          child_ends.each { |io| close_io(io) }
        end
        @preloader_pgid = @own_groups ? @preloader_pid : nil
        @children[@preloader_pid] = PRELOADER
        @control_io = control_r
        @workers.each { |handle| handle.env = env.merge("TURBO_TESTS_WORKER" => handle.id.to_s) }
      end

      # From the control pipe.
      def forked(row)
        handle = @workers[row[:worker].to_i - 1]
        return nil unless handle

        handle.pid = row[:pid]
        handle.pgid = nil
        handle.launched = true
        handle.test_env_number = row[:test_env_number] || number_for(handle)
        handle
      end

      def worker_exited(row)
        handle = @workers[row[:worker].to_i - 1]
        return nil unless handle

        [handle, ExitInfo.new(row[:exitstatus], row[:termsig])]
      end

      def preloader_alive?
        @children.key?(@preloader_pid)
      end

      # Forked workers share the preloader's process group: signal them by
      # pid only, the group is signalled as a whole by #signal_all.
      def signal(handle, signal)
        return false unless handle.pid

        Process.kill(Pool.windows? ? "KILL" : signal, handle.pid)
        true
      rescue Errno::ESRCH, Errno::EPERM, RangeError
        false
      end

      def signal_all(signal)
        @workers.each { |handle| signal(handle, signal) if handle.pid }
        signal_preloader(signal)
        kill_group(@preloader_pgid, signal)
      end

      def signal_preloader(signal)
        return false unless @preloader_pid && preloader_alive?

        Process.kill(signal, @preloader_pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def close
        close_io(@alive_w)
        super
        close_io(@control_io)
      end

      def verbose_lines
        command = COMMAND.join(" ")
        ["Preloader: pid #{@preloader_pid} #{command}"] + super
      end
    end
  end
end
