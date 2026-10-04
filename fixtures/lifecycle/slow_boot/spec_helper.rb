# A slow application boot: preloading pays it once, every booting process
# pays it again.
File.open(ENV["TURBO_TESTS_FIXTURE_LOG"], "a") { |f| f.puts("boot #{Process.pid}") } if ENV["TURBO_TESTS_FIXTURE_LOG"]
sleep 2
