# Loaded by the preloader (--preload): a process forked, not exec'ed, while
# the application loads inherits every pipe, including the preloader's
# control pipe. The run must still finish.
pid = fork do
  trap("TERM") {}
  sleep 300
end
Process.detach(pid)
File.open(ENV.fetch("TURBO_TESTS_FIXTURE_LOG"), "a") { |f| f.puts "grandchild #{pid}" }
