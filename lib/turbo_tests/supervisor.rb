# frozen_string_literal: true

module TurboTests
  # Runs the pool: one thread, one IO.select loop over every worker's rows
  # and output pipes, the preloader's control pipe and a self-pipe for
  # signals. Keeps three facts apart that 2.x conflated: protocol completion
  # (job_finished / close), process exit (reaped status) and stream EOF.
  #
  # Per worker: pending -> booting -> ready -> busy -> idle -> ready ...
  #   -> shutting_down -> exited, or -> terminating -> killing -> exited
  # when it does not exit within --exit-timeout (diagnostics, TERM, 5s, KILL).
  class Supervisor
    TERM_GRACE = 5.0
    KILL_GRACE = 5.0
    DRAIN_GRACE = 1.0
    POLL_INTERVAL = 0.05
    EXAMPLE_ROWS = %w[example_passed example_failed example_pending].freeze

    class Slot
      attr_accessor :handle, :state, :job, :jobs, :exit_info, :reaped_at, :exit_row, :deadline, :deadline_kind,
        :drain_deadline, :diagnostics, :error, :times, :rspec_closed, :hung, :crashed, :started_at, :counted

      def initialize(handle)
        @handle = handle
        @state = :pending
        @jobs = []
        @times = Hash.new(0.0)
        @exit_row = false
        @rspec_closed = false
        @hung = false
        @crashed = false
        @counted = false
      end

      def id
        handle.id
      end

      def files
        jobs.flat_map(&:files)
      end

      def reaped?
        !exit_info.nil?
      end
    end

    IoEntry = Struct.new(:slot, :kind, :buffer, :reader)

    attr_reader :config_row, :total_examples, :runtimes, :slots, :unknown_example_ids
    attr_accessor :scheduler

    def initialize(pool, scheduler, reporter, options, job_args: [], out: $stdout, err: $stderr)
      @pool = pool
      @scheduler = scheduler
      @reporter = reporter
      @options = options
      @job_args = job_args
      @out = out
      @err = err
      @slots = pool.workers.map { |handle| Slot.new(handle) }
      @io_map = {}
      @pending_rows = []
      @reporting = false
      @stopping = false
      @aborted = false
      @interrupts = 0
      @terminated = false
      @killing_all = false
      @failures = 0
      @exit_codes = []
      @total_examples = 0
      @runtimes = {}
      @unknown_example_ids = []
      @config_row = nil
      @boot_errors = []
      @preloader_info = nil
      @preloader_settled = false
      @preloader_deadline = nil
      @preloader_kill_stage = nil
      @control_drain_deadline = nil
      @output_broken = false
      @output_dirty = false
      @verbose_printed = false
      @signal_reader = nil
      @signal_writer = nil
      @signals = nil
      @previous_handlers = nil
      @booted = false
      @finished = false
      @probe_row = nil
      @preloader_kill_stage = nil
    end

    def exit_timeout
      timeout = @options.exit_timeout
      timeout.nil? || timeout.to_f <= 0 ? nil : timeout.to_f
    end

    # Starts the processes and runs the loop until TEST_ENV_NUMBER of the
    # first worker is known (and the config row arrived when it is needed),
    # without dispatching jobs. Rows meant for the reporter are kept.
    def boot(wait_for_config: false)
      @booted = true
      install_signal_handlers
      begin
        @pool.start
      rescue SystemCallError => e
        @err.puts "turbo_tests: could not start workers: #{e.class}: #{e.message}"
        @aborted = true
      end
      register_ios
      until boot_complete?(wait_for_config)
        iterate
      end
      self
    end

    def aborted?
      @aborted
    end

    def test_env_numbers
      @pool.test_env_numbers
    end

    # For errors raised before #run (it cleans up after itself).
    def emergency_stop
      @killing_all = true
      @pool.signal_all("KILL")
      @pool.close
      restore_signal_handlers
    rescue StandardError
      nil
    end

    # Dispatches jobs until every worker is gone; returns the exit status.
    def run
      boot unless @booted
      @reporting = true
      @pending_rows.each { |slot, row| deliver(slot, row) }
      @pending_rows.clear
      print_verbose
      if @aborted
        abort_all
      elsif @pool.respond_to?(:launch_job)
        launch_commands
      else
        @slots.each { |slot| dispatch(slot) if slot.state == :ready }
      end
      iterate until finished?
      warn_unrun_jobs
      @finished = true
      exit_status
    ensure
      unless @finished
        @killing_all = true
        @pool.signal_all("TERM")
      end
      finish
    end

    private

    # ---- loop -------------------------------------------------------------

    def iterate
      ios = @io_map.keys
      ready = ios.empty? ? sleep_for(next_timeout) : IO.select(ios, nil, nil, next_timeout)
      ready[0].each { |io| read(io) } if ready
      flush_output
      handle_signals
      reap
      check_deadlines
      sync_launched
    end

    def sleep_for(seconds)
      sleep(seconds)
      nil
    end

    def next_timeout
      now = monotonic
      deadlines = @slots.flat_map { |slot| [slot.deadline, slot.drain_deadline] }.compact
      deadlines << @preloader_deadline if @preloader_deadline
      deadlines << @control_drain_deadline if @control_drain_deadline
      nearest = deadlines.min
      timeout = POLL_INTERVAL
      timeout = [[nearest - now, 0].max, timeout].min if nearest
      timeout
    end

    def boot_complete?(wait_for_config)
      return true if @aborted
      return true if @slots.all? { |slot| slot_done?(slot) } && pool_settled?

      known = !@pool.first_env_number.nil?
      return true if known && (!wait_for_config || !@config_row.nil?)

      answering = fork_pool? ? @preloader_settled : @slots.reject { |slot| slot.state == :pending }.all?(&:reaped?)
      # The config row comes from the preloader or from worker 1 only.
      answering ||= !fork_pool? && @config_row.nil? && @slots.first && @slots.first.reaped?
      if answering
        # Nobody is left to answer (the probing worker or the preloader died).
        @aborted = true
        return true
      end
      false
    end

    def finished?
      @slots.all? { |slot| slot_done?(slot) } && pool_settled?
    end

    def slot_done?(slot)
      if slot.state == :pending
        return true if @aborted || @killing_all
        return true if fork_pool? && @preloader_settled
        return true if command_pool? && @reporting

        return false
      end
      slot.reaped? && slot_ios(slot).empty?
    end

    def pool_settled?
      return true unless fork_pool?

      @preloader_settled
    end

    def fork_pool?
      @pool.respond_to?(:preloader_alive?)
    end

    def command_pool?
      @pool.respond_to?(:launch_job)
    end

    # ---- ios --------------------------------------------------------------

    def register_ios
      if @pool.control_io && !@io_map.key?(@pool.control_io)
        @io_map[@pool.control_io] = IoEntry.new(nil, :control, Protocol::LineBuffer.new, nil)
      end
      @slots.each { |slot| register_slot(slot) }
      return if @signal_reader.nil? || @io_map.key?(@signal_reader)

      @io_map[@signal_reader] = IoEntry.new(nil, :signal, nil, nil)
    end

    def register_slot(slot)
      handle = slot.handle
      if handle.rows_io && !handle.rows_io.closed? && !@io_map.key?(handle.rows_io)
        @io_map[handle.rows_io] = IoEntry.new(slot, :rows, Protocol::LineBuffer.new, Protocol::Reader.new)
      end
      if handle.out_io && !handle.out_io.closed? && !@io_map.key?(handle.out_io)
        reader = handle.prefix ? Protocol::Reader.new(handle.prefix) : nil
        @io_map[handle.out_io] = IoEntry.new(slot, :out, Protocol::LineBuffer.new, reader)
      end
      slot.state = :booting if slot.state == :pending && handle.launched
      slot.started_at ||= monotonic if handle.launched
    end

    def sync_launched
      @slots.each { |slot| register_slot(slot) if slot.state == :pending && slot.handle.launched }
    end

    def slot_ios(slot)
      @io_map.select { |_io, entry| entry.slot.equal?(slot) }.keys
    end

    def read(io)
      entry = @io_map[io]
      return unless entry

      if entry.kind == :signal
        drain_signal_pipe(io)
        return
      end

      chunk = io.read_nonblock(65_536, exception: false)
      return if chunk == :wait_readable

      if chunk.nil?
        finish_io(io)
        return
      end

      entry.buffer << chunk
      entry.buffer.each_line { |line| process_line(entry, line) }
    rescue IOError, Errno::EIO, Errno::ECONNRESET, Errno::EBADF
      finish_io(io)
    end

    def finish_io(io)
      entry = @io_map.delete(io)
      if entry && entry.buffer
        rest = entry.buffer.flush
        process_line(entry, rest) unless rest.empty?
      end
      close_io(io)
      preloader_control_closed if entry && entry.kind == :control
    end

    def close_io(io)
      io.close unless io.closed?
    rescue IOError, SystemCallError
      nil
    end

    def close_slot_ios(slot)
      slot_ios(slot).each { |io| finish_io(io) }
    end

    def process_line(entry, line)
      case entry.kind
      when :control
        row = Protocol.decode(line)
        row ? handle_control(row) : output(line)
      when :rows
        begin
          entry.reader.parse_line(line).each { |_kind, row| handle_row(entry.slot, row) }
        rescue Protocol::Error => e
          @err.puts "turbo_tests: worker #{entry.slot.id}: #{e.message}"
        end
      when :out
        if entry.reader
          entry.reader.parse_line(line).each do |kind, value|
            kind == :row ? handle_row(entry.slot, value) : output(value)
          end
        else
          output(line)
        end
      end
    end

    def output(text)
      return if text.nil? || text.empty? || @output_broken

      # Windows workers already wrote through a text-mode stdout (\r\n); our
      # own text-mode stdout would turn that into \r\r\n.
      text = text.gsub("\r\n".b, "\n".b) if Pool.windows?
      @out.write(text)
      @output_dirty = true
    rescue Errno::EPIPE, IOError
      @output_broken = true
    end

    def flush_output
      return unless @output_dirty

      @output_dirty = false
      @out.flush if @out.respond_to?(:flush)
    rescue Errno::EPIPE, IOError
      @output_broken = true
    end

    # ---- rows -------------------------------------------------------------

    def handle_control(row)
      case row[:type].to_s
      when "config"
        handle_config(row)
      when "env_number"
        env_number_known(row)
      when "forked"
        handle = @pool.forked(row)
        slot = handle && @slots[handle.id - 1]
        register_slot(slot) if slot
      when "worker_exited"
        handle, info = @pool.worker_exited(row)
        process_exited(@slots[handle.id - 1], info) if handle
      when "error"
        boot_error(nil, row)
      else
        to_reporter(nil, row)
      end
    end

    def handle_row(slot, row)
      case row[:type].to_s
      when "ready"
        worker_ready(slot, row)
      when "config"
        handle_config(row)
      when "env_number"
        env_number_known(row)
      when "error"
        boot_error(slot, row)
      when "job_finished"
        job_finished(slot, row)
      when "exit"
        slot.exit_row = true
      when "close"
        slot.rspec_closed = true
        start_deadline(slot, :exit) if command_pool? && slot.state == :busy
        to_reporter(slot, row)
      else
        if EXAMPLE_ROWS.include?(row[:type].to_s)
          @total_examples += 1
          record_example_time(slot, row[:example])
        end
        to_reporter(slot, row)
      end
    end

    def to_reporter(slot, row)
      row[:worker] = slot.id if slot && !row.key?(:worker)
      if @reporting
        deliver(slot, row)
      else
        @pending_rows << [slot, row]
      end
    end

    def deliver(_slot, row)
      result = @reporter.handle(row)
      count_failure if result == :failure
      result
    end

    def handle_config(row)
      return if @config_row

      @config_row = row
      if @reporter.respond_to?(:config)
        @reporter.config(row)
      end
      @reporter.fail_fast = fail_fast_limit if @reporter.respond_to?(:fail_fast=) && fail_fast_limit
    end

    def env_number_known(row)
      value = row[:value].to_s
      @probe_row = row
      return unless @pool.first_env_number.nil?

      @pool.first_env_number = value
      begin
        @pool.launch_remaining
      rescue SystemCallError => e
        @err.puts "turbo_tests: could not start workers: #{e.class}: #{e.message}"
        @aborted = true
      end
      register_ios
    end

    def boot_error(slot, row)
      slot.error = row if slot
      @boot_errors << row
      unless row[:reported]
        text = row[:message].to_s
        unless text.start_with?("An error occurred")
          text = slot ? "An error occurred in worker #{slot.id}: #{text}" : "An error occurred while preloading: #{text}"
        end
        text = "#{text}\n#{Array(row[:backtrace]).first(20).map { |line| "# #{line}" }.join("\n")}" if row[:backtrace]
        to_reporter(slot, type: "message", message: text)
      end
      @aborted = true
      stop_dispatching
    end

    def worker_ready(slot, row)
      slot.handle.pid ||= row[:pid]
      slot.handle.test_env_number = row[:test_env_number] if row.key?(:test_env_number)
      slot.started_at ||= monotonic
      return unless [:pending, :booting, :idle, :ready].include?(slot.state)

      slot.state = :ready
      dispatch(slot) if @reporting
    end

    def dispatch(slot)
      return unless slot.state == :ready
      return shutdown(slot) if @stopping || @aborted || @scheduler.nil?

      job = @scheduler.next_job(slot.id)
      return shutdown(slot) unless job

      slot.job = job
      slot.jobs << job
      slot.times = Hash.new(0.0)
      slot.state = :busy
      # A worker that cannot take the job is gone: its exit reports the files.
      send_row(slot, type: "job", id: job.id, files: job.files, args: @job_args)
    end

    def send_row(slot, row)
      io = slot.handle.jobs_io
      return false if io.nil? || io.closed?

      io.write(Protocol.encode(row))
      true
    rescue IOError, SystemCallError
      false
    end

    def shutdown(slot)
      return if [:shutting_down, :terminating, :killing, :exited].include?(slot.state)

      send_row(slot, type: "shutdown")
      close_io(slot.handle.jobs_io) if slot.handle.jobs_io
      slot.state = :shutting_down
      start_deadline(slot, :exit)
    end

    def start_deadline(slot, kind)
      return if slot.reaped?

      timeout = exit_timeout
      if timeout.nil?
        slot.deadline = nil
      else
        slot.deadline = monotonic + timeout
        slot.deadline_kind = kind
      end
    end

    def job_finished(slot, row)
      job = slot.job
      return unless job && row[:job_id] == job.id

      duration = row[:duration].to_f
      @scheduler.report(job, duration) if @scheduler
      @exit_codes << row[:exit_code].to_i unless row[:exit_code].nil?
      @unknown_example_ids.concat(Array(row[:unknown_example_ids]).map(&:to_s))
      record_runtimes(job, duration, slot.times)
      slot.job = nil
      slot.state = :idle
    end

    # ---- fail-fast and signals --------------------------------------------

    def fail_fast_limit
      return @options.fail_fast if @options.fail_fast

      value = @config_row && @config_row[:fail_fast]
      return 1 if value == true
      return value if value.is_a?(Integer) && value > 0

      nil
    end

    def count_failure
      @failures += 1
      limit = fail_fast_limit
      stop_dispatching(true) if limit && @failures >= limit
    end

    # Stops handing out jobs; idle workers shut down, busy ones are asked to
    # stop after their current example (INT) and get --exit-timeout to do so.
    def stop_dispatching(interrupt_busy = false)
      return if @stopping

      @stopping = true
      @scheduler.cancel if @scheduler
      @slots.each do |slot|
        case slot.state
        when :ready
          shutdown(slot)
        when :busy
          next unless interrupt_busy

          # Windows has no SIGINT for other processes: let the job finish.
          @pool.signal(slot.handle, "INT") unless Pool.windows?
          start_deadline(slot, :cancel)
        end
      end
    end

    def install_signal_handlers
      return if @signal_reader

      @signal_reader, @signal_writer = IO.pipe
      @previous_handlers = {}
      %w[INT TERM].each do |signal|
        begin
          @previous_handlers[signal] = trap(signal) do
            begin
              @signal_writer.write_nonblock(signal[0])
            rescue StandardError
              nil
            end
          end
        rescue ArgumentError
          nil
        end
      end
    end

    def restore_signal_handlers
      return unless @previous_handlers

      @previous_handlers.each do |signal, handler|
        begin
          trap(signal, handler || "DEFAULT")
        rescue ArgumentError
          nil
        end
      end
      @previous_handlers = nil
    end

    def drain_signal_pipe(io)
      chunk = io.read_nonblock(64, exception: false)
      return if chunk == :wait_readable || chunk.nil?

      @signals = (@signals || "") + chunk
    rescue IOError
      nil
    end

    def handle_signals
      return unless @signals && !@signals.empty?

      signals = @signals
      @signals = ""
      signals.each_char do |signal|
        if signal == "T"
          @terminated = true
          kill_all("TERM")
        else
          @interrupts += 1
          if @interrupts == 1
            first_interrupt
          else
            kill_all("KILL")
          end
        end
      end
    end

    # In a terminal Ctrl-C already reached the workers (same process group);
    # otherwise forward it.
    def first_interrupt
      forward = @pool.own_process_groups?
      @stopping = true
      @scheduler.cancel if @scheduler
      @pool.signal_preloader("INT") if forward && fork_pool?
      @slots.each do |slot|
        case slot.state
        when :ready, :idle
          shutdown(slot)
        when :booting
          @pool.signal(slot.handle, "INT") if forward
          shutdown(slot)
        when :busy
          @pool.signal(slot.handle, "INT") if forward
          start_deadline(slot, :cancel)
        end
      end
      @aborted = true unless @reporting
    end

    def kill_all(signal)
      @killing_all = true
      @stopping = true
      @scheduler.cancel if @scheduler
      @pool.signal_all(signal)
      @slots.each do |slot|
        next if slot.reaped?

        slot.state = :killing unless slot.state == :pending
        slot.deadline = monotonic + KILL_GRACE
        slot.deadline_kind = :kill
      end
      @preloader_deadline = monotonic + KILL_GRACE if fork_pool? && !@preloader_settled
    end

    def abort_all
      @stopping = true
      @slots.each do |slot|
        case slot.state
        when :ready, :booting, :idle, :busy
          shutdown(slot)
        end
      end
    end

    # ---- process exits ----------------------------------------------------

    def reap
      @pool.reap.each do |handle, info|
        if handle == Pool::Fork::PRELOADER
          preloader_exited(info)
        else
          process_exited(@slots[handle.id - 1], info)
        end
      end
    end

    def process_exited(slot, info)
      return if slot.nil? || slot.reaped?

      slot.exit_info = info
      slot.reaped_at = monotonic
      slot.deadline = nil
      @pool.kill_group(slot.handle.pgid, "TERM") if slot.handle.pgid

      if slot.hung
        report_hung(slot)
      elsif slot.job && command_pool? && slot.rspec_closed
        command_job_finished(slot, info)
      elsif slot.job
        report_crash(slot, info, slot.job.files)
        @scheduler.report(slot.job, 0.0) if @scheduler
        slot.job = nil
      elsif [:shutting_down, :killing].include?(slot.state) || @killing_all || slot.error
        nil
      elsif slot.state != :pending
        report_crash(slot, info, [])
      end

      count_exit_code(slot, info)
      slot.state = :exited
      slot.drain_deadline = monotonic + DRAIN_GRACE
    end

    def count_exit_code(slot, info)
      return if slot.counted || slot.hung || slot.crashed || @killing_all

      slot.counted = true
      @exit_codes << info.exitstatus if info.exitstatus && info.exitstatus != 0
    end

    def command_job_finished(slot, info)
      job = slot.job
      duration = monotonic - (slot.started_at || monotonic)
      @scheduler.report(job, duration) if @scheduler
      @exit_codes << info.exitstatus.to_i unless info.exitstatus.nil?
      record_runtimes(job, duration, slot.times)
      slot.job = nil
    end

    def report_crash(slot, info, files, status = nil)
      return if slot.crashed

      slot.crashed = true
      status ||= info.exitstatus.nil? && info.termsig.nil? ? "unknown" : info.to_s
      if @reporter.respond_to?(:worker_crashed)
        @reporter.worker_crashed(slot.id, files, status)
      else
        @err.puts "Worker #{slot.id} exited with status #{status} before finishing. Files: #{files.join(" ")}"
      end
    end

    def report_hung(slot)
      return if slot.crashed

      slot.crashed = true
      timeout = exit_timeout
      if @reporter.respond_to?(:worker_hung)
        reporter_call(:worker_hung, slot.id, slot.files, slot.diagnostics, timeout)
      else
        @err.puts "Worker #{slot.id} did not exit #{format("%g", timeout.to_f)}s after finishing RSpec; killed. Files: #{slot.files.join(" ")}"
        @err.puts slot.diagnostics if slot.diagnostics
      end
    end

    def reporter_call(name, *args)
      method = @reporter.method(name)
      arity = method.arity
      args = args.first(arity) if arity >= 0
      if arity < 0
        required = -arity - 1
        optional = method.parameters.count { |type, _| type == :opt }
        rest = method.parameters.any? { |type, _| type == :rest }
        args = args.first(required + optional) unless rest
      end
      method.call(*args)
    end

    def preloader_exited(info)
      @preloader_info = info
      @preloader_deadline = nil
      @pool.kill_group(@pool.preloader_pgid, "TERM") if @pool.preloader_pgid && @slots.all?(&:reaped?)
      if @io_map.key?(@pool.control_io)
        # A process the application forked while loading inherits the control
        # pipe and would keep it open forever; stop waiting for EOF after a grace.
        @control_drain_deadline = monotonic + DRAIN_GRACE
      else
        preloader_control_closed
      end
    end

    # The control pipe is drained once the preloader is gone: every
    # worker_exited row it sent has been processed.
    def preloader_control_closed
      return unless @preloader_info && !@preloader_settled
      return if @io_map.key?(@pool.control_io)

      @preloader_settled = true
      @exit_codes << @preloader_info.exitstatus if @preloader_info.exitstatus && @preloader_info.exitstatus != 0 && !@killing_all
      orphans = @slots.reject(&:reaped?)
      return if orphans.empty?

      unless @killing_all || @aborted
        @err.puts "turbo_tests: the preloader exited (status #{@preloader_info}) before its workers"
      end
      # Forked workers whose pid never reached us are in the same group.
      @pool.kill_group(@pool.preloader_pgid, "KILL") if @pool.preloader_pgid
      orphans.each do |slot|
        if slot.state == :pending && slot.handle.pid.nil?
          next if @aborted || @killing_all

          slot.exit_info = Pool::ExitInfo.new(nil, nil)
          report_crash(slot, slot.exit_info, [], "unknown (never forked: the preloader exited with status #{@preloader_info})")
          next
        end

        @pool.signal(slot.handle, "KILL") if slot.handle.pid
        process_exited(slot, Pool::ExitInfo.new(nil, nil))
      end
      @aborted = true unless @reporting
    end

    # ---- deadlines --------------------------------------------------------

    def check_deadlines
      now = monotonic
      if @control_drain_deadline && now >= @control_drain_deadline
        @control_drain_deadline = nil
        if @io_map.key?(@pool.control_io)
          @io_map.delete(@pool.control_io)
          close_io(@pool.control_io)
        end
        preloader_control_closed
      end
      @slots.each do |slot|
        if slot.drain_deadline && now >= slot.drain_deadline
          slot.drain_deadline = nil
          close_slot_ios(slot)
        end
        next unless slot.deadline && now >= slot.deadline

        case slot.deadline_kind
        when :exit, :cancel
          hang_detected(slot)
        when :term
          @pool.signal(slot.handle, "KILL")
          slot.state = :killing
          slot.deadline = monotonic + KILL_GRACE
          slot.deadline_kind = :kill
        when :kill
          slot.deadline = nil
          give_up(slot)
        end
      end
      check_preloader_deadline(now)
    end

    def hang_detected(slot)
      return if slot.reaped?

      handle = slot.handle
      slot.hung = true
      if handle.pid
        pipes = [["rows", handle.rows_io], ["output", handle.out_io]].reject { |_name, io| io.nil? || io.closed? }
        slot.diagnostics = Diagnostics.collect(handle.pid, pipes: pipes, pgid: handle.pgid, diagnose: @options.diagnose)
      end
      @pool.signal(handle, "TERM")
      slot.state = :terminating
      slot.deadline = monotonic + TERM_GRACE
      slot.deadline_kind = :term
    end

    # KILL did not make it exit (uninterruptible sleep, or a forked worker
    # whose preloader is gone): stop waiting for it.
    def give_up(slot)
      @err.puts "turbo_tests: worker #{slot.id} (pid #{slot.handle.pid}) survived SIGKILL; not waiting for it"
      process_exited(slot, Pool::ExitInfo.new(nil, Signal.list["KILL"]))
      close_slot_ios(slot)
    end

    def check_preloader_deadline(now)
      return unless fork_pool? && !@preloader_settled

      if @preloader_deadline.nil?
        return unless @pool.preloader_alive? && @slots.all?(&:reaped?)

        timeout = exit_timeout
        @preloader_deadline = timeout ? now + timeout : nil
        return
      end
      return if now < @preloader_deadline

      case @preloader_kill_stage
      when nil
        @err.puts "turbo_tests: the preloader did not exit #{format("%g", exit_timeout.to_f)}s after its workers; killing it"
        @err.puts Diagnostics.collect(@pool.preloader_pid, pgid: @pool.preloader_pgid, diagnose: @options.diagnose)
        @pool.signal_preloader("TERM")
        @preloader_kill_stage = :term
        @preloader_deadline = now + TERM_GRACE
        @exit_codes << 1
      when :term
        @pool.signal_preloader("KILL")
        @preloader_kill_stage = :kill
        @preloader_deadline = now + KILL_GRACE
      else
        @preloader_info ||= Pool::ExitInfo.new(nil, Signal.list["KILL"])
        @preloader_deadline = nil
        close_io(@pool.control_io)
        @io_map.delete(@pool.control_io)
        preloader_control_closed
      end
    end

    # ---- command pool -----------------------------------------------------

    def launch_commands
      @slots.each do |slot|
        job = @scheduler && !@stopping ? @scheduler.next_job(slot.id) : nil
        next unless job

        begin
          @pool.launch_job(slot.handle, job, @job_args)
        rescue SystemCallError => e
          @err.puts "turbo_tests: could not start rspec: #{e.class}: #{e.message}"
          @scheduler.report(job, 0.0)
          slot.jobs << job
          slot.crashed = true
          @aborted = true
          next
        end
        slot.job = job
        slot.jobs << job
        register_slot(slot)
        slot.state = :busy
        slot.started_at = monotonic
      end
      print_verbose(true)
    end

    # ---- runtimes ---------------------------------------------------------

    def record_example_time(slot, example)
      return unless example.is_a?(Hash)

      run_time = example[:run_time]
      return unless run_time.is_a?(Numeric)

      path = example_file(example)
      slot.times[path] += run_time.to_f if path
    end

    def example_file(example)
      id = example[:id]
      path = id.is_a?(String) ? id.sub(/\[[\d:,\s]*\]\z/, "") : nil
      path ||= example[:file_path] if example[:file_path].is_a?(String)
      path && RuntimeLog.normalize(path)
    end

    # Single-file jobs record their own wall time; packed jobs split theirs
    # by the files' example run times. Jobs with line or id selectors ran a
    # subset of their file and are not recorded.
    def record_runtimes(job, duration, times)
      return if job.files.any? { |file| Files.path_of(file) != file }

      files = job.files.map { |file| RuntimeLog.normalize(file) }.uniq
      if files.size == 1
        @runtimes[files.first] = duration
        return
      end

      total = files.inject(0.0) { |sum, file| sum + times[file].to_f }
      files.each do |file|
        @runtimes[file] = total > 0 ? duration * times[file].to_f / total : duration / files.size
      end
    end

    # ---- end of run -------------------------------------------------------

    def warn_unrun_jobs
      return unless @scheduler && @scheduler.pending? && !@stopping && !@aborted

      @err.puts "turbo_tests: #{@scheduler.size} job(s) were not run: no worker was left"
      @exit_codes << 1
    end

    def exit_status
      return 130 if @interrupts > 0
      return 143 if @terminated

      failed = reporter_failed? ||
        @exit_codes.any? { |code| code != 0 } ||
        @slots.any? { |slot| slot.hung || slot.crashed } ||
        @aborted || @interrupts > 0 ||
        no_examples_failure?
      return 0 unless failed

      [@exit_codes.max || 0, 1].max
    end

    def reporter_failed?
      return !@reporter.success? if @reporter.respond_to?(:success?)

      !@reporter.failed_examples.empty?
    end

    def no_examples_failure?
      @config_row && @config_row[:fail_if_no_examples] && @total_examples.zero?
    end

    def finish
      if @options.print_failed_group && @reporter.respond_to?(:worker_files=)
        @reporter.print_failed_group = true if @reporter.respond_to?(:print_failed_group=)
        files = {}
        @slots.each { |slot| files[slot.id] = slot.files unless slot.files.empty? }
        @reporter.worker_files = files
      end
      @io_map.keys.each { |io| close_io(io) unless io.equal?(@signal_reader) }
      @io_map.clear
      @pool.close
      restore_signal_handlers
      close_io(@signal_reader) if @signal_reader
      close_io(@signal_writer) if @signal_writer
      flush_output
    end

    def print_verbose(force = false)
      return unless @options.verbose
      return if @verbose_printed

      return if command_pool? && !force

      @verbose_printed = true
      flush_output
      @out.flush if @out.respond_to?(:flush)
      details = ["pool=#{@pool.name}", "workers=#{@slots.size}"]
      details << "scheduler=#{@scheduler.mode}" if @scheduler
      details << "own_process_groups=#{@pool.own_process_groups?}"
      @err.puts "turbo_tests: #{details.join(" ")}"
      if @probe_row
        how = @probe_row[:probed] ? "probed" : "given"
        @err.puts "turbo_tests: TEST_ENV_NUMBER of the first worker #{how}: #{@probe_row[:value].to_s.inspect}"
      end
      @pool.verbose_lines.each { |line| @err.puts line }
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
