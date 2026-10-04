# frozen_string_literal: true

require "rbconfig"
require "securerandom"

require_relative "base"

module TurboTests
  module Pool
    # N long-lived `ruby -rturbo_tests/worker` processes, each booting the
    # application itself. Used where fork is unavailable (Windows, JRuby,
    # TruffleRuby) or with --pool spawn.
    class Spawn < Base
      COMMAND = [RbConfig.ruby, "-I", LIB, "-r", "turbo_tests/worker", "-e", "TurboTests::Worker.main"].freeze

      # Without a known convention worker 1 boots with a provisional
      # TEST_ENV_NUMBER="" and probes which value the first worker should use;
      # the other workers' numbers (2..N) never depend on the answer, so they
      # boot concurrently instead of waiting a full application boot.
      def start
        @workers.each do |handle|
          if handle.id == 1 && @first_env_number.nil?
            launch(handle, "", true)
          else
            launch(handle, number_for(handle), false)
          end
        end
      end

      def launch_remaining
        @workers.each { |handle| launch(handle, number_for(handle), false) unless handle.launched }
      end

      private

      def launch(handle, number, probe)
        jobs_r, jobs_w = pipe
        out_r, out_w = pipe
        rows_r = rows_w = nil
        env = worker_env(handle, number)
        env["TURBO_TESTS_PROBE"] = probe ? "1" : nil
        opts = spawn_options(jobs_r, out_w)
        if dedicated_rows?
          rows_r, rows_w = pipe
          env[Protocol::ROWS_FD_ENV] = "3"
          env[Protocol::PREFIX_ENV] = nil
          opts[3] = rows_w
        else
          handle.prefix = SecureRandom.uuid
          env[Protocol::ROWS_FD_ENV] = nil
          env[Protocol::PREFIX_ENV] = handle.prefix
        end

        begin
          pid = Process.spawn(env, *COMMAND, opts)
        ensure
          [jobs_r, out_w, rows_w].each { |io| close_io(io) }
        end
        jobs_w.sync = true
        handle.jobs_io = jobs_w
        handle.out_io = out_r
        handle.rows_io = rows_r
        handle.command = COMMAND
        handle.env = env
        handle.test_env_number = number
        register(handle, pid)
      end
    end
  end
end
