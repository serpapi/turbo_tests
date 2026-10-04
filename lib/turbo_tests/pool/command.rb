# frozen_string_literal: true

require "securerandom"

require_relative "base"

module TurboTests
  module Pool
    # The 2.x model: one `rspec` process per static group (RSPEC_EXECUTABLE,
    # else `bundle exec rspec` under Bundler, else `rspec`), rows mixed into
    # its stdout behind a per-process prefix. The escape hatch for suites
    # that are not safe to run in persistent workers.
    class Command < Base
      def self.rspec_command(env = ENV)
        executable = env["RSPEC_EXECUTABLE"]
        return executable.split if executable && !executable.strip.empty?
        return [env["BUNDLE_BIN_PATH"], "exec", "rspec"] if env["BUNDLE_BIN_PATH"] && !env["BUNDLE_BIN_PATH"].empty?

        ["rspec"]
      end

      def dedicated_rows?
        false
      end

      # Workers start when the supervisor hands them their group.
      def start
        nil
      end

      def launch_job(handle, job, args)
        out_r, out_w = pipe
        handle.prefix = SecureRandom.uuid
        number = number_for(handle)
        env = worker_env(handle, number)
        env[Protocol::PREFIX_ENV] = handle.prefix
        env[Protocol::ROWS_FD_ENV] = nil
        env["RUBYOPT"] = ["-I#{LIB}", "-rturbo_tests/diagnostics", @env_base["RUBYOPT"]].compact.join(" ")
        env["TURBO_TESTS_EXIT_WATCHDOG"] = @env_base["TURBO_TESTS_EXIT_TIMEOUT"]
        command = Command.rspec_command + args + job.files
        command = ["nice"] + command if @options.nice && !Pool.windows?

        begin
          pid = Process.spawn(env, *command, spawn_options(File::NULL, out_w))
        ensure
          close_io(out_w)
        end
        handle.out_io = out_r
        handle.command = command
        handle.env = env
        handle.test_env_number = number
        register(handle, pid)
      end
    end
  end
end
