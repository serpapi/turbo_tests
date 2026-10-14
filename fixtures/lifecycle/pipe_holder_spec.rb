# The example leaves a grandchild that inherits the worker's stdout: the pipe
# stays open after the worker exits.
RSpec.describe "pipe holder" do
  it "spawns a long-lived child holding the output pipe" do
    pid = Process.spawn("sleep", "300")
    Process.detach(pid)
    File.open(ENV.fetch("TURBO_TESTS_FIXTURE_LOG"), "a") { |f| f.flock(File::LOCK_EX); f.seek(0, IO::SEEK_END); f.puts("grandchild #{pid}") } if ENV["TURBO_TESTS_FIXTURE_LOG"]
    expect(pid).to be > 0
  end
end
