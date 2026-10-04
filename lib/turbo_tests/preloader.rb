# frozen_string_literal: true

require "json"
require "rspec/core"

require_relative "protocol"
require_relative "json_rows_formatter"
require_relative "hooks"
require_relative "env_number"
require_relative "diagnostics"
require_relative "worker"

module TurboTests
  # The fork pool's child: boots once, forks every worker, then stays alive
  # only to reap them and report each exit to the parent.
  #
  # Control rows (to the parent): rows emitted while preloading (e.g. an
  # error loading spec_helper), config, env_number, forked, worker_exited,
  # error.
  module Preloader
    module_function

    def main(env = ENV)
      $stdout.sync = true
      $stderr.sync = true
      control_fd = Integer(env.fetch("TURBO_TESTS_CONTROL_FD"))
      @parent_alive = env["TURBO_TESTS_PARENT_FD"] && IO.for_fd(Integer(env["TURBO_TESTS_PARENT_FD"]), "r")
      @worker_fds = env.fetch("TURBO_TESTS_PIPES").split(";").map { |fds| fds.split(",").map { |fd| Integer(fd) } }
      ENV[Protocol::ROWS_FD_ENV] = control_fd.to_s
      @control = Protocol.default_writer($stdout)

      first = boot(env)
      exit(1) if first.nil?

      fork_workers(first)
      exit(reap)
    end

    # Returns the first worker's TEST_ENV_NUMBER, nil when preloading failed.
    def boot(env)
      RSpec::Core::Runner.disable_autorun! if RSpec::Core::Runner.respond_to?(:disable_autorun!)
      Worker.hide_own_frames
      Worker.nice(env)
      Hooks.load_project_file
      initial_seed = RSpec.configuration.seed
      Worker.configure_base(Worker.base_args(env), env["TURBO_TESTS_PRELOAD"])
      silence = RSpec.configuration.silence_filter_announcements
      if RSpec.world.wants_to_quit
        write(type: "error", message: "Preloading failed (see the error above).", reported: true)
        return nil
      end

      seed = env["TURBO_TESTS_SEED"].to_s =~ /\A\d+\z/ ? env["TURBO_TESTS_SEED"].to_i : nil
      Worker.apply_seed(seed, initial_seed)
      write(Worker.config_row(silence))

      first = env.key?("TURBO_TESTS_FIRST_ENV_NUMBER") ? env["TURBO_TESTS_FIRST_ENV_NUMBER"] : nil
      first = EnvNumber.probe if first.nil? || env["TURBO_TESTS_PROBE"] == "1"
      write(type: "env_number", value: first, probed: env["TURBO_TESTS_PROBE"] == "1")

      TurboTests.hooks.run_before_fork
      warmup
      first
    rescue EnvNumber::Ambiguous => e
      write(type: "error", message: e.message)
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise if e.is_a?(SystemExit) || e.is_a?(Interrupt)

      write(type: "error", message: "An error occurred while preloading: #{e.class}: #{e.message}", backtrace: e.backtrace)
      nil
    end

    def warmup
      warmed = Process.respond_to?(:warmup) ? Process.warmup : nil
      unless warmed
        GC.start
        if GC.respond_to?(:compact)
          begin
            GC.compact
          rescue NotImplementedError
            nil
          end
        end
      end
    end

    def fork_workers(first)
      @pids = {}
      open_fds = @worker_fds.dup
      @worker_fds.each_with_index do |fds, index|
        number = index.zero? ? first.to_s : (index + 1).to_s
        pid = Process.fork do
          worker(index + 1, fds, open_fds - [fds], number)
        end
        @pids[pid] = index + 1
        write(type: "forked", worker: index + 1, pid: pid, test_env_number: number)
        fds.each { |fd| close_fd(fd) }
        open_fds.delete(fds)
      end
      # Workers handle INT themselves; the preloader must outlive them.
      trap("INT") {}
    end

    def worker(number, fds, other_fds, test_env_number)
      jobs_fd, rows_fd, out_fd = fds
      Protocol.reset_rows_io
      other_fds.flatten.each { |fd| close_fd(fd) }
      @parent_alive.close if @parent_alive && !@parent_alive.closed?

      ENV["TEST_ENV_NUMBER"] = test_env_number
      ENV["TURBO_TESTS_WORKER"] = number.to_s
      ENV[Protocol::ROWS_FD_ENV] = rows_fd.to_s
      ENV.delete("TURBO_TESTS_PIPES")
      ENV.delete("TURBO_TESTS_CONTROL_FD")

      jobs = IO.for_fd(jobs_fd, "r")
      $stdin.reopen(jobs)
      jobs.close
      out = IO.for_fd(out_fd, "w")
      $stdout.reopen(out)
      out.close
      $stdout.sync = true

      TurboTests.hooks.run_after_fork(number)
      status = Worker.new(ENV, booted: true).run
      exit(status)
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise if e.is_a?(SystemExit)
      exit!(1) if e.is_a?(Errno::EPIPE)

      $stderr.puts "turbo_tests: worker #{number} failed after fork: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.join("\n") if e.backtrace
      exit!(1)
    end

    # Workers are reaped by pid. wait2(-1) is avoided: on Ruby 2.7 its
    # SIGCHLD-based implementation loses a child's exit when another thread
    # waits on a specific pid (a Process.detach started by the application).
    def reap
      watch_parent
      until @pids.empty?
        reaped = false
        @pids.keys.each do |pid|
          result = begin
            Process.wait2(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            [pid, nil]
          rescue Interrupt
            nil
          end
          next unless result

          reaped = true
          number = @pids.delete(pid)
          status = result[1]
          write(type: "worker_exited", worker: number, pid: pid,
                exitstatus: status && status.exitstatus, termsig: status && status.termsig)
        end
        sleep 0.05 unless reaped || @pids.empty?
      end
      @parent_gone ? 1 : 0
    end

    # The parent holds the only write end of this pipe and never writes: EOF
    # means it exited (or was killed) while workers still run. The workers
    # are then terminated and reaped by the main loop above.
    def watch_parent
      return unless @parent_alive

      Thread.new do
        begin
          IO.select([@parent_alive])
          @parent_gone = true
          terminate_orphaned_workers
        rescue IOError, SystemCallError
          nil
        end
      end
    end

    def terminate_orphaned_workers
      ["TERM", "KILL"].each do |signal|
        pids = @pids.keys
        break if pids.empty?

        pids.each do |pid|
          begin
            Process.kill(signal, pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
        sleep 5 if signal == "TERM"
      end
    end

    def write(row)
      @control.write(row)
    rescue IOError, SystemCallError
      nil
    end

    def close_fd(fd)
      IO.for_fd(fd).close
    rescue SystemCallError, IOError, ArgumentError
      nil
    end
  end
end
