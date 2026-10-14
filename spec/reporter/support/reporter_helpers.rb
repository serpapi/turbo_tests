# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"

require "turbo_tests/protocol"

# Runs real RSpec processes for the reporter specs: a worker emitting rows the
# way turbo_tests workers do on this platform (a dedicated file descriptor, or
# on Windows prefixed lines mixed into stdout), a serial rspec run for
# comparison, and a parent-like process replaying rows into formatters.
module ReporterHelpers
  REPO_ROOT = File.expand_path("../../..", __dir__)
  LIB = File.join(REPO_ROOT, "lib")
  FIXTURES = File.join(REPO_ROOT, "fixtures", "reporter")
  TIMEOUT = 120
  ANSI = /\e\[[\d;]*m/.freeze

  Result = Struct.new(:stdout, :stderr, :status, :rows)

  REPLAY_SCRIPT = <<~'SCRIPT'
    require "json"
    ENV.fetch("REPLAY_REQUIRES", "").split(",").each { |library| require library }
    require "turbo_tests/reporter"
    format, count = ARGV
    rows = $stdin.each_line.map { |line| JSON.parse(line, symbolize_names: true) }
    reporter = TurboTests::Reporter.from_config(
      [{ name: format, outputs: ["-"] }], RSpec::Core::Time.now, nil, false
    )
    expected = count.to_s.empty? ? rows.count { |row| row[:type].to_s.start_with?("example_") } : Integer(count)
    reporter.report(expected) { |r| rows.each { |row| r.handle(row) } }
  SCRIPT


  @worker_runs = {}

  class << self
    attr_reader :worker_runs
  end

  module_function

  def fixture_path(name)
    File.join(FIXTURES, name)
  end

  def rspec_command
    [RbConfig.ruby, Gem.bin_path("rspec-core", "rspec")]
  end

  def strip_ansi(text)
    text.gsub(ANSI, "")
  end

  def normalize_timing(text)
    text.gsub(/Finished in [\d.]+ seconds? \(files took [\d.]+ seconds? to load\)/, "Finished in N seconds (files took N seconds to load)")
  end

  # Runs `command` with `chdir`, returns Result. Extra fd redirects are passed
  # to spawn; `rows_reader` is read concurrently and parsed as rows.
  def capture(env, command, chdir:, stdin_data: "", redirects: {}, rows_reader: nil, unbundled: false)
    run = lambda do
      Open3.popen3(env, *command, { chdir: chdir }.merge(redirects)) do |stdin, stdout, stderr, wait_thr|
        redirects.each_value { |io| io.close if io.respond_to?(:close) && !io.closed? }
        readers = [stdout, stderr, rows_reader].compact.map { |io| Thread.new { io.read } }
        stdin.write(stdin_data)
        stdin.close
        unless wait_thr.join(TIMEOUT)
          Process.kill(:KILL, wait_thr.pid)
          raise "#{command.join(" ")} did not finish in #{TIMEOUT}s"
        end
        out, err, rows = readers.map(&:value)
        Result.new(out, err, wait_thr.value, rows && parse_rows(rows))
      end
    end
    unbundled && defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
  end

  def parse_rows(text)
    text.each_line.map { |line| JSON.parse(line, symbolize_names: true) }
  end

  # A worker run: rspec with TurboTests::JsonRowsFormatter writing rows to a
  # dedicated pipe mapped to fd 3 (TURBO_TESTS_ROWS_FD) or, on Windows, prefixed
  # lines on stdout (RSPEC_FORMATTER_OUTPUT_ID); memoized per process.
  def run_worker(fixture, *args, env: {}, unbundled: false)
    key = [fixture, args, env, unbundled]
    ReporterHelpers.worker_runs[key] ||= if Gem.win_platform? || ENV["TURBO_TESTS_SPEC_MIXED_ROWS"]
      run_worker_mixed(fixture, *args, env: env, unbundled: unbundled)
    else
      run_worker_dedicated(fixture, *args, env: env, unbundled: unbundled)
    end
  end

  def worker_command(args)
    rspec_command + ["-I", LIB, "-r", "turbo_tests/json_rows_formatter",
                     "--format", "TurboTests::JsonRowsFormatter", *args]
  end

  # Windows cannot hand a child an extra descriptor: rows share stdout behind
  # a per-run prefix and are split out here like Pool::Spawn does.
  def run_worker_mixed(fixture, *args, env:, unbundled:)
    prefix = "turbo-tests-rows-#{Process.pid}-#{rand(1 << 32)}:"
    result = capture(
      { "TURBO_TESTS_ROWS_FD" => nil, "RSPEC_FORMATTER_OUTPUT_ID" => prefix, "TEST_ENV_NUMBER" => nil }.merge(env),
      worker_command(args),
      chdir: fixture_path(fixture),
      unbundled: unbundled
    )
    reader = TurboTests::Protocol::Reader.new(prefix)
    output = +""
    rows = []
    result.stdout.each_line do |line|
      reader.parse_line(line).each do |kind, item|
        kind == :row ? rows << item : output << item
      end
    end
    Result.new(output, result.stderr, result.status, rows)
  end

  def run_worker_dedicated(fixture, *args, env:, unbundled:)
    rows_r, rows_w = IO.pipe
    capture(
      { "TURBO_TESTS_ROWS_FD" => "3", "RSPEC_FORMATTER_OUTPUT_ID" => nil, "TEST_ENV_NUMBER" => nil }.merge(env),
      worker_command(args),
      chdir: fixture_path(fixture),
      redirects: { 3 => rows_w },
      rows_reader: rows_r,
      unbundled: unbundled
    )
  ensure
    rows_r.close if rows_r && !rows_r.closed?
    rows_w.close if rows_w && !rows_w.closed?
  end

  def run_serial(fixture, *args, env: {}, unbundled: false)
    capture(
      { "TEST_ENV_NUMBER" => nil }.merge(env),
      rspec_command + args,
      chdir: fixture_path(fixture),
      unbundled: unbundled
    )
  end

  # A parent-like process in the fixture directory replaying rows into one
  # formatter (no banner: the start notification gets the example count).
  def replay(fixture, rows, format, requires: [], count: nil, unbundled: false)
    capture(
      { "TEST_ENV_NUMBER" => nil, "REPLAY_REQUIRES" => requires.join(",") },
      [RbConfig.ruby, "-I", LIB, "-e", REPLAY_SCRIPT, "--", format, count.to_s],
      chdir: fixture_path(fixture),
      stdin_data: rows.map { |row| JSON.generate(row) }.join("\n") + "\n",
      unbundled: unbundled
    )
  end

  # Whether a plain `ruby` outside this bundle can require `library`: an
  # installed gem, or RUBYLIB pointing at an unpacked gem's lib directory.
  def available_outside_bundle?(library)
    capture({}, [RbConfig.ruby, "-e", "require #{library.inspect}"], chdir: REPO_ROOT, unbundled: true).status.success?
  end

  # Reporter in this process with StringIO outputs.
  def in_process_reporter(format: "progress", seed: 1234, seed_used: false)
    out = StringIO.new
    err = StringIO.new
    reporter = TurboTests::Reporter.from_config(
      [{ name: format, outputs: ["-"] }], RSpec::Core::Time.now, seed, seed_used, out: out, err: err
    )
    [reporter, out, err]
  end
end
