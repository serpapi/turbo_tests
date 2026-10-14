# A slow application boot: preloading pays it once, every booting process
# pays it again.
File.open(ENV["TURBO_TESTS_FIXTURE_LOG"], "a") { |f| f.flock(File::LOCK_EX); f.seek(0, IO::SEEK_END); f.puts("boot #{Process.pid}") } if ENV["TURBO_TESTS_FIXTURE_LOG"]
sleep 2
