RSpec.configure do |config|
  config.example_status_persistence_file_path = ENV.fetch("TURBO_TESTS_FIXTURE_STATUS", "tmp/only_failures_status.txt")

  # Records, per worker, whether the status file already existed when the worker
  # shut down: the parent writes it after the run, so it must not.
  if (seen = ENV["TURBO_TESTS_FIXTURE_STATUS_SEEN"])
    config.after(:suite) do
      File.open(seen, "a") { |f| f.flock(File::LOCK_EX); f.seek(0, IO::SEEK_END); f.puts(File.exist?(config.example_status_persistence_file_path) ? "present" : "absent") }
    end
  end
end
