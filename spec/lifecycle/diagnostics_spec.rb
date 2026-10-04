require "rbconfig"
require "open3"
require_relative "lifecycle_helper"

RSpec.describe TurboTests::Diagnostics do
  describe "Linux /proc readers (fake proc tree)" do
    let(:root) { Dir.mktmpdir("proc", LifecycleHelper.tmp_root) }

    after { FileUtils.rm_rf(root) }

    def write(path, content)
      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def link(path, target)
      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.symlink(target, full)
    end

    before do
      write("123/status", "Name:\truby\nState:\tS (sleeping)\nPPid:\t100\nThreads:\t2\nVmRSS:\t1000 kB\nUid:\t1\n")
      write("123/wchan", "do_wait")
      write("123/stat", "123 (ruby) S 100 123 123 0")
      write("123/cmdline", "ruby\x00-e\x00worker\x00")
      write("123/task/123/stat", "123 (ruby) S 100 123")
      write("123/task/123/wchan", "futex_wait_queue")
      write("123/task/124/stat", "124 (stuck thread) D 100 123")
      write("123/task/124/wchan", "pipe_write")
      link("123/fd/1", "pipe:[999]")
      link("123/fd/5", "pipe:[555]")
      write("456/stat", "456 (sleep) S 123 123 123 0")
      write("456/cmdline", "sleep\x00300\x00")
      link("456/fd/1", "pipe:[999]")
      write("789/stat", "789 (other) S 1 789 789 0")
      link("789/fd/0", "pipe:[111]")
      link("self/fd/7", "pipe:[999]")
    end

    it "detects a proc tree" do
      expect(described_class.linux_proc?(root)).to be(true)
      expect(described_class.linux_proc?(File.join(root, "missing"))).to be(false)
    end

    it "reads process state and wait channel" do
      expect(described_class.process_status(123, root))
        .to eq(["Name:\truby", "State:\tS (sleeping)", "PPid:\t100", "Threads:\t2", "VmRSS:\t1000 kB", "wchan: do_wait"])
    end

    it "lists every thread with its state and kernel wait channel" do
      expect(described_class.task_states(123, root)).to eq([
        "tid 123 (ruby) state=S wchan=futex_wait_queue",
        "tid 124 (stuck thread) state=D wchan=pipe_write"
      ])
    end

    it "finds which processes hold a pipe" do
      io = double("pipe", fileno: 7, closed?: false)

      holders = described_class.pipe_holders(io, root)

      expect(holders).to eq(["pid 123 fds 1 ruby -e worker", "pid 456 fds 1 sleep 300"])
    end

    it "lists the members of a process group" do
      expect(described_class.group_members(123, root)).to eq([
        "pid 123 ppid 100 state S ruby -e worker",
        "pid 456 ppid 123 state S sleep 300"
      ])
    end
  end

  describe ".capture" do
    it "returns command output" do
      expect(described_class.capture(["echo", "hello"], 5)).to eq("hello\n")
    end

    it "gives up on commands that outlive the timeout" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(described_class.capture(["sleep", "5"], 0.3)).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    it "returns nil for missing commands" do
      expect(described_class.capture(["turbo-tests-no-such-command"], 1)).to be_nil
    end
  end

  describe ".start_exit_watchdog" do
    let(:lib) { File.expand_path("../../lib", __dir__) }

    def ruby(script, timeout:)
      stdout, stderr, status = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Open3.popen3(RbConfig.ruby, "-I", lib, "-rturbo_tests/diagnostics", "-e", script) do |stdin, out, err, thread|
        stdin.close
        unless thread.join(timeout)
          Process.kill(:KILL, thread.pid)
          thread.join
        end
        stdout = out.read
        stderr = err.read
        status = thread.value
      end
      [stdout, stderr, status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end

    it "costs nothing on a normal exit" do
      _out, err, status, wall = ruby(<<~RUBY, timeout: 10)
        Thread.new { sleep }
        TurboTests::Diagnostics.start_exit_watchdog(20, "test")
      RUBY

      expect(status.success?).to be(true)
      expect(err).to eq("")
      expect(wall).to be < 3
    end

    it "names a thread that blocks the exit from its ensure block" do
      _out, err, status, = ruby(<<~RUBY, timeout: 4)
        Thread.new do
          begin
            sleep
          ensure
            sleep
          end
        end
        sleep 0.1
        TurboTests::Diagnostics.start_exit_watchdog(1, "test worker")
      RUBY

      expect(status.signaled?).to be(true)
      expect(err).to include("test worker still alive 0.5s after finishing RSpec", "ensure block")
      expect(err).to match(/-e:1 sleep>/)
      expect(err).to match(/-e:3:in .*sleep/)
    end
  end
end
