# frozen_string_literal: true

require "rbconfig"

module TurboTests
  # Evidence for "the process will not exit": thread stacks, kernel wait
  # channels, open descriptors and who holds our pipes. Everything is
  # best-effort, bounded in time and limited to stacks/fds (no app data).
  module Diagnostics
    COMMAND_TIMEOUT = 5.0
    GEM_FRAME = %r{/gems/([^/]+?)-\d[^/]*/}.freeze

    @proc_root = nil
    @exit_watchdog_installed = false

    module_function

    def proc_root
      @proc_root || "/proc"
    end

    def proc_root=(path)
      @proc_root = path
    end

    def linux_proc?(root = proc_root)
      File.directory?(File.join(root, "self")) || File.directory?(File.join(root, "1"))
    end

    def macos?
      RbConfig::CONFIG["host_os"] =~ /darwin/ ? true : false
    end

    # ---- in-process report (worker exit watchdog) -------------------------

    # Started when a worker finished RSpec: if the process is still alive
    # timeout/2 seconds later (stuck after(:suite) hook, at_exit handler or a
    # thread that refuses to die) it prints what every thread is doing. It
    # defers its own termination, so it survives Ruby's "kill all threads"
    # exit phase, but gets out of the way as soon as every other thread is
    # gone: a normal exit costs at most one 10ms poll.
    def start_exit_watchdog(timeout, label)
      return nil if timeout.nil? || timeout <= 0 || !Thread.respond_to?(:handle_interrupt)

      grace = timeout / 2.0
      started = Queue.new
      watchdog = Thread.new do
        Thread.handle_interrupt(Object => :never) do
          snapshot = backtrace_snapshot
          started << true
          deadline = monotonic + grace
          stuck = true
          while monotonic < deadline
            if Thread.pending_interrupt? && others_finished?
              stuck = false
              break
            end
            sleep 0.01
          end
          report($stderr, "#{label} still alive #{format("%g", grace)}s after finishing RSpec", snapshot) if stuck
        end
      end
      watchdog.name = "turbo_tests exit watchdog" if watchdog.respond_to?(:name=)
      # A thread that has not entered handle_interrupt yet would be killed
      # right away by Ruby's exit.
      started.pop
      watchdog
    end

    def backtrace_snapshot
      snapshot = {}
      Thread.list.each do |thread|
        next if thread == Thread.current

        snapshot[thread] = thread.backtrace
      end
      snapshot
    end

    def others_finished?
      Thread.list.all? { |thread| thread == Thread.main || thread == Thread.current || !thread.alive? }
    end

    # For processes turbo_tests does not control (the command pool runs
    # plain `rspec`): RUBYOPT=-rturbo_tests/diagnostics plus
    # TURBO_TESTS_EXIT_WATCHDOG=<seconds> starts the watchdog once every
    # other at_exit handler ran.
    def install_exit_watchdog_from_env(env = ENV)
      timeout = env["TURBO_TESTS_EXIT_WATCHDOG"].to_s
      return false unless timeout =~ /\A\d+(\.\d+)?\z/ && timeout.to_f > 0
      return false if @exit_watchdog_installed

      # Only for this process, not for Ruby processes the tests start.
      env.delete("TURBO_TESTS_EXIT_WATCHDOG")

      @exit_watchdog_installed = true
      label = "rspec (worker #{env["TURBO_TESTS_WORKER"]}, pid #{Process.pid})"
      at_exit { start_exit_watchdog(timeout.to_f, label) }
      true
    end

    def report(io = $stderr, reason = nil, snapshot = {})
      io.write(report_text(reason, snapshot))
      io.flush if io.respond_to?(:flush)
    rescue StandardError, IOError
      nil
    end

    HIDDEN_BACKTRACE = "Ruby hides the backtrace of a thread it is killing: this thread was told to die on exit " \
      "but does not finish (an ensure block or Thread.handle_interrupt that never returns blocks the process exit)"

    def report_text(reason = nil, snapshot = {})
      lines = ["turbo_tests diagnostics: pid #{Process.pid}#{reason ? " (#{reason})" : ""}"]
      blocked_gems = []
      Thread.list.each do |thread|
        lines << thread_header(thread)
        next if thread == Thread.current

        backtrace = thread.backtrace
        if backtrace.nil? && thread.alive?
          lines << "    (#{HIDDEN_BACKTRACE}; backtrace when finishing RSpec:)"
          backtrace = snapshot[thread]
        end
        backtrace ||= []
        backtrace.each { |frame| lines << "    #{frame}" }
        if thread.status == "sleep"
          backtrace.each do |frame|
            match = GEM_FRAME.match(frame)
            blocked_gems << match[1] if match
          end
        end
      end
      lines << "  gems in blocked threads: #{blocked_gems.uniq.join(", ")}" unless blocked_gems.empty?
      lines << "  live objects: #{object_counts}"
      lines.concat(open_fds(Process.pid).map { |line| "  #{line}" })
      lines.concat(task_states("self").map { |line| "  #{line}" })
      "#{lines.join("\n")}\n"
    end

    def thread_header(thread)
      details = []
      details << "name=#{thread.name.inspect}" if thread.respond_to?(:name) && thread.name
      details << "status=#{thread.status.inspect}"
      native = begin
        thread.native_thread_id if thread.respond_to?(:native_thread_id)
      rescue StandardError
        nil
      end
      details << "native_thread_id=#{native}" if native
      details << "main" if thread == Thread.main
      details << "current" if thread == Thread.current
      "  #{thread.inspect} #{details.join(" ")}"
    end

    def object_counts
      counts = {}
      [Thread, IO].each do |klass|
        counts[klass.name] = ObjectSpace.each_object(klass).count { |object| klass != IO || !object.closed? }
      end
      if defined?(::BasicSocket)
        counts["Socket"] = ObjectSpace.each_object(::BasicSocket).count { |socket| !socket.closed? }
      end
      counts.map { |name, count| "#{name}=#{count}" }.join(" ")
    rescue StandardError, NotImplementedError
      "unavailable"
    end

    def open_fds(pid)
      dir = File.join(proc_root, pid == Process.pid ? "self" : pid.to_s, "fd")
      if File.directory?(dir)
        entries = Dir.entries(dir).reject { |name| name.start_with?(".") }.sort_by(&:to_i)
        return ["open fds: #{entries.map { |fd| "#{fd}->#{readlink(File.join(dir, fd))}" }.join(" ")}"]
      end

      output = capture(["lsof", "-nP", "-p", pid.to_s], 3.0)
      return [] unless output

      fds = output.lines.select { |line| line.split[3].to_s =~ /\A\d/ }
      ["open fds (lsof):"] + fds.map { |line| "  #{line.chomp}" }
    end

    # ---- parent-side collection before killing a hung worker ---------------

    # pid: the hung process; pipes: our read ends of its rows/out pipes;
    # pgid: its process group (when it has its own).
    def collect(pid, pipes: [], pgid: nil, diagnose: false)
      sections = []
      sections << section("process #{pid}", process_status(pid))
      sections << section("threads (kernel wait channels)", task_states(pid))
      sections << section("processes in group #{pgid}", group_members(pgid)) if pgid
      pipes.each do |name, io|
        sections << section("holders of the #{name} pipe", pipe_holders(io))
      end
      sections << section("sample", sample(pid)) if macos?
      sections.concat(deep_profile(pid)) if diagnose
      sections.compact.join("\n")
    rescue StandardError => e
      "diagnostics failed: #{e.class}: #{e.message}"
    end

    def section(title, lines)
      lines = Array(lines)
      return nil if lines.empty?

      (["--- #{title}"] + lines.map { |line| "  #{line}" }).join("\n")
    end

    def process_status(pid, root = proc_root)
      dir = File.join(root, pid.to_s)
      if File.directory?(dir)
        lines = []
        status = read(File.join(dir, "status"))
        if status
          status.each_line do |line|
            lines << line.chomp if line =~ /\A(Name|State|PPid|Threads|SigBlk|SigIgn|SigCgt|VmRSS):/
          end
        end
        wchan = read(File.join(dir, "wchan"))
        lines << "wchan: #{wchan.strip}" if wchan && !wchan.strip.empty?
        return lines
      end

      output = capture(["ps", "-o", "pid,ppid,pgid,stat,etime,command", "-p", pid.to_s], 3.0)
      output ? output.lines.map(&:chomp) : []
    end

    # Per-thread state and wait channel: D-state or a stable wchan points at
    # the kernel, "S" + futex_wait at a lock.
    def task_states(pid, root = proc_root)
      dir = File.join(root, pid.to_s, "task")
      return [] unless File.directory?(dir)

      Dir.entries(dir).reject { |name| name.start_with?(".") }.sort_by(&:to_i).map do |tid|
        stat = read(File.join(dir, tid, "stat")).to_s
        comm = stat[/\((.*)\)/, 1]
        state = stat.sub(/\A.*\)\s*/, "")[0]
        wchan = read(File.join(dir, tid, "wchan")).to_s.strip
        "tid #{tid}#{comm ? " (#{comm})" : ""} state=#{state || "?"} wchan=#{wchan.empty? ? "-" : wchan}"
      end
    end

    def group_members(pgid, root = proc_root)
      if linux_proc?(root)
        members = []
        each_pid(root) do |pid|
          stat = read(File.join(root, pid, "stat")).to_s
          fields = stat.sub(/\A.*\)\s*/, "").split
          next unless fields[2] && fields[2].to_i == pgid

          cmdline = read(File.join(root, pid, "cmdline")).to_s.tr("\0", " ").strip
          members << "pid #{pid} ppid #{fields[1]} state #{fields[0]} #{cmdline[0, 200]}"
        end
        return members
      end

      output = capture(["ps", "-A", "-o", "pid=,ppid=,pgid=,stat=,command="], 3.0)
      return [] unless output

      output.lines.select { |line| line.split[2].to_i == pgid }.map { |line| line.strip[0, 240] }
    end

    # Which processes hold the other end of one of our pipes: proves (or
    # disproves) "a descendant keeps the pipe open".
    def pipe_holders(io, root = proc_root)
      return [] if io.nil? || io.closed?

      if linux_proc?(root)
        inode = pipe_inode(io, root)
        return [] unless inode

        target = "pipe:[#{inode}]"
        holders = []
        each_pid(root) do |pid|
          next if pid.to_i == Process.pid

          fd_dir = File.join(root, pid, "fd")
          entries = begin
            Dir.entries(fd_dir)
          rescue SystemCallError
            next
          end
          fds = entries.select { |fd| readlink(File.join(fd_dir, fd)) == target }
          next if fds.empty?

          cmdline = read(File.join(root, pid, "cmdline")).to_s.tr("\0", " ").strip
          holders << "pid #{pid} fds #{fds.sort_by(&:to_i).join(",")} #{cmdline[0, 200]}"
        end
        return holders
      end

      lsof_pipe_holders(io)
    end

    def pipe_inode(io, root = proc_root)
      link = readlink(File.join(root, "self", "fd", io.fileno.to_s))
      link && link[/\Apipe:\[(\d+)\]\z/, 1]
    end

    # macOS: lsof prints our read end as "PIPE 0x<ours> 16384 ->0x<peer>";
    # writers show the peer address as their own.
    def lsof_pipe_holders(io)
      ours = capture(["lsof", "-nP", "-a", "-p", Process.pid.to_s, "-d", io.fileno.to_s], 3.0)
      return [] unless ours

      peer = ours[/->(0x\h+)/, 1]
      return [] unless peer

      all = capture(["lsof", "-nP"], COMMAND_TIMEOUT)
      return ["(lsof timed out)"] unless all

      all.lines.select do |line|
        fields = line.split
        line.include?("PIPE") && fields.include?(peer) && fields[1].to_i != Process.pid
      end.map { |line| fields = line.split; "#{fields[0]} pid #{fields[1]} fd #{fields[3]}" }.uniq
    end

    def sample(pid)
      return [] unless executable?("sample")

      output = capture(["sample", pid.to_s, "1", "-mayDie", "-file", "/dev/stdout"], COMMAND_TIMEOUT)
      return [] unless output

      lines = output.lines.map(&:chomp)
      start = lines.index { |line| line =~ /\ACall graph:/ } || 0
      stop = lines.index { |line| line =~ /\ABinary Images:/ } || lines.size
      lines[start...[stop, start + 150].min] || []
    end

    def deep_profile(pid)
      sections = []
      dir = File.join("tmp", "turbo_tests")
      if executable?("perf")
        require "fileutils"
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "perf-#{pid}.data")
        output = capture(["perf", "record", "-g", "-p", pid.to_s, "-o", path, "--", "sleep", "3"], 10.0)
        sections << section("perf record", [output ? "saved #{path}" : "perf record failed or timed out"])
      end
      if executable?("bpftrace")
        script = "tracepoint:raw_syscalls:sys_enter /pid == #{Integer(pid)}/ { @[tid, args->id] = count(); } " \
          "interval:s:3 { exit(); }"
        output = capture(["bpftrace", "-e", script], 10.0)
        sections << section("bpftrace syscalls by thread (3s)", output ? output.lines.map(&:chomp).last(60) : ["bpftrace failed or timed out"])
      end
      sections.compact
    end

    # ---- helpers -----------------------------------------------------------

    def each_pid(root)
      Dir.entries(root).select { |name| name =~ /\A\d+\z/ }.sort_by(&:to_i).each { |name| yield name }
    rescue SystemCallError
      nil
    end

    def read(path)
      File.read(path)
    rescue SystemCallError, IOError
      nil
    end

    def readlink(path)
      File.readlink(path)
    rescue SystemCallError, NotImplementedError
      nil
    end

    def executable?(name)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, name)
        File.file?(path) && File.executable?(path)
      end
    end

    # Runs argv (no shell) and returns stdout+stderr, or nil when it cannot be
    # run or does not finish within timeout seconds.
    def capture(argv, timeout = COMMAND_TIMEOUT)
      return nil unless executable?(argv.first)

      reader, writer = IO.pipe
      pid = begin
        Process.spawn(*argv, in: File::NULL, out: writer, err: writer)
      rescue SystemCallError
        nil
      end
      writer.close
      return nil unless pid

      output = "".b
      deadline = monotonic + timeout
      loop do
        remaining = deadline - monotonic
        break if remaining <= 0

        ready = IO.select([reader], nil, nil, remaining)
        next unless ready

        begin
          output << reader.read_nonblock(65_536)
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
      end
      finished = nil
      loop do
        finished = Process.wait2(pid, Process::WNOHANG)
        break if finished || monotonic >= deadline

        sleep 0.01
      end
      unless finished
        begin
          Process.kill("KILL", pid)
        rescue SystemCallError
          nil
        end
        Process.wait2(pid)
        return nil
      end
      output.force_encoding(Encoding::UTF_8).scrub
    rescue SystemCallError, IOError
      nil
    ensure
      reader.close if reader && !reader.closed?
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

TurboTests::Diagnostics.install_exit_watchdog_from_env
