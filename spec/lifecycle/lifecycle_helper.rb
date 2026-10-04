require "rbconfig"
require "tmpdir"
require "fileutils"

# Runs bin/turbo_tests as a real subprocess. stdin is a pipe (not a TTY), so
# workers get their own process groups, as on CI.
module LifecycleHelper
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin", "turbo_tests")
  FIXTURES = "fixtures/lifecycle"
  POOLS = %w[fork spawn command].freeze

  class Result
    attr_reader :stdout, :stderr, :status, :wall, :pipes_closed

    def initialize(stdout, stderr, status, wall, pipes_closed)
      @stdout = stdout
      @stderr = stderr
      @status = status
      @wall = wall
      @pipes_closed = pipes_closed
    end

    def exitstatus
      status.exitstatus
    end

    def output
      "#{stdout}#{stderr}"
    end

    def inspect
      "#<Result exit=#{exitstatus.inspect} wall=#{wall.round(2)}\n--- stdout\n#{stdout}\n--- stderr\n#{stderr}>"
    end
    alias_method :to_s, :inspect
  end

  def self.tmp_root
    path = File.join(ROOT, "tmp", "lifecycle")
    FileUtils.mkdir_p(path)
    path
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Waits for the run and for EOF on its output; output still held open by
  # a leftover process `drain` seconds after the exit is reported via
  # Result#pipes_closed instead of hanging the suite.
  def turbo_tests(*args, env: {}, chdir: ROOT, timeout: 120, drain: 5)
    started = monotonic
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    in_r, in_w = IO.pipe
    pid = Process.spawn(env, RbConfig.ruby, BIN, *args, in: in_r, out: out_w, err: err_w, chdir: chdir, pgroup: true)
    [out_w, err_w, in_r].each(&:close)
    buffers = {out_r => +"", err_r => +""}
    open = buffers.keys
    status = nil
    exited_at = nil
    loop do
      if status.nil?
        _, status = Process.wait2(pid, Process::WNOHANG)
        exited_at = monotonic if status
      end
      break if status && open.empty?
      break if exited_at && monotonic - exited_at > drain

      if monotonic - started > timeout
        Process.kill(:KILL, -pid) rescue nil
        Process.wait(pid) rescue nil
        raise "turbo_tests #{args.join(" ")} did not finish in #{timeout}s:\n#{buffers.values.join("\n")}"
      end

      ready = IO.select(open, nil, nil, 0.05)
      next unless ready

      ready[0].each do |io|
        chunk = io.read_nonblock(65_536, exception: false)
        next if chunk == :wait_readable

        if chunk.nil?
          open.delete(io)
        else
          buffers[io] << chunk
        end
      end
    end
    Result.new(buffers[out_r].force_encoding(Encoding::BINARY), buffers[err_r].force_encoding(Encoding::BINARY), status,
      monotonic - started, open.empty?)
  ensure
    [out_r, err_r, in_w].each { |io| io.close if io && !io.closed? }
  end

  def alive?(pid)
    Process.kill(0, pid)
    state = IO.popen(["ps", "-o", "stat=", "-p", Integer(pid).to_s], &:read).strip
    !state.empty? && !state.start_with?("Z")
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def eventually_dead?(pids, within: 3)
    deadline = monotonic + within
    loop do
      alive = pids.select { |pid| alive?(pid) }
      return true if alive.empty?
      return false if monotonic > deadline

      sleep 0.05
    end
  end

  def fixture_log
    @fixture_log ||= begin
      dir = Dir.mktmpdir("run", LifecycleHelper.tmp_root)
      File.join(dir, "fixture.log")
    end
  end

  def fixture_lines
    File.exist?(fixture_log) ? File.read(fixture_log).lines.map(&:chomp) : []
  end

  def plain(text)
    text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(/\e\[[\d;]*m/, "")
  end
end

RSpec.configure do |config|
  config.include LifecycleHelper, file_path: %r{spec/lifecycle/}
  config.after(:each, file_path: %r{spec/lifecycle/}) do
    FileUtils.rm_rf(File.dirname(@fixture_log)) if @fixture_log
  end
end
