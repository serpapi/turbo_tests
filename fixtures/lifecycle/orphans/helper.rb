def turbo_tests_fixture_log(line)
  path = ENV["TURBO_TESTS_FIXTURE_LOG"]
  File.open(path, "a") { |f| f.puts(line) } if path
end

# Failing files wait until the slow file left its grandchild behind, so
# fail-fast always interrupts a busy worker, however loaded the machine is.
def wait_for_grandchild(timeout = 20)
  path = ENV["TURBO_TESTS_FIXTURE_LOG"]
  return unless path

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until (File.exist?(path) && File.read(path).include?("grandchild")) ||
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.05
  end
end
