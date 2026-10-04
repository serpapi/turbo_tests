# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "set"
require "rspec/core"

require_relative "fake_example"

module TurboTests
  Error = Class.new(StandardError) unless const_defined?(:Error, false)

  # Replays the rows workers emit into real RSpec formatters in the parent
  # process and owns everything printed once per run: the banner, run options,
  # the seed, merged profile, deduplicated deprecations, worker errors and the
  # final summary.
  class Reporter
    BUILT_IN_FORMATTERS = {
      "p" => :ProgressFormatter,
      "progress" => :ProgressFormatter,
      "d" => :DocumentationFormatter,
      "doc" => :DocumentationFormatter,
      "documentation" => :DocumentationFormatter,
      "j" => :JsonFormatter,
      "json" => :JsonFormatter,
      "f" => :FailureListFormatter,
      "failures" => :FailureListFormatter
    }.freeze

    CONSTANT_PATH = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/.freeze

    # Notifications only formatters implement; `close`, `message` and `start`
    # are too generic (IO#close, Exception#message) to identify a formatter.
    FORMATTER_NOTIFICATIONS = %i[
      deprecation deprecation_summary dump_failures dump_pending dump_profile dump_summary
      example_failed example_finished example_group_finished example_group_started
      example_passed example_pending example_started seed start_dump stop
    ].freeze

    ROW_TYPES_WITHOUT_OUTPUT = %w[
      close deprecation_summary ready job_finished exit forked worker_exited error
    ].freeze

    # Rows whose display order matters to formatters that render group nesting.
    SEQUENCED_ROWS = %w[group_started group_finished example_passed example_pending example_failed message close].freeze

    NO_EXAMPLES_FOUND = "No examples found."
    ALL_FILTERED_OUT = "\nAll examples were filtered out"
    RUN_OPTIONS = /\A\s*Run options:/.freeze
    ERROR_OUTSIDE_OF_EXAMPLES =
      /\A\s*(?:An error occurred |While loading .* an `exit` \/ `raise SystemExit` occurred)/m.freeze

    # RSpec's summary plus hung/crashed workers, and rerun commands computed
    # from the examples this process saw (RSpec.world is empty in the parent).
    class Summary < RSpec::Core::Notifications::SummaryNotification
      attr_accessor :worker_errors_count

      def totals_line
        line = super
        count = worker_errors_count.to_i
        return line if count.zero?

        "#{line}, #{RSpec::Core::Formatters::Helpers.pluralize(count, "worker error")}"
      end

      def colorized_totals_line(colorizer = ::RSpec::Core::Formatters::ConsoleCodes)
        return super if worker_errors_count.to_i.zero?

        colorizer.wrap(totals_line, RSpec.configuration.failure_color)
      end

      private

      def duplicate_rerun_locations
        @duplicate_rerun_locations ||= begin
          counts = Hash.new(0)
          examples.each { |example| counts[example.location_rerun_argument] += 1 }
          Set.new(counts.select { |_location, count| count > 1 }.keys)
        end
      end
    end

    def self.from_config(formatter_config, start_time, seed, seed_used, out: $stdout, err: $stderr)
      reporter = new(start_time, seed, seed_used, out: out, err: err)

      formatter_config.each do |config|
        name, outputs = config.values_at(:name, :outputs)
        formatter_class = formatter_class(name)

        streams = Array(outputs).map do |filename|
          filename == "-" ? out : reporter.open_output(filename)
        end
        streams = [out] if streams.empty?

        reporter.add(formatter_class, streams)
      end

      reporter
    end

    # Built-in names as in `rspec --format`, otherwise a constant path that is
    # already loaded (or loadable like RSpec does: `Fuubar` -> require
    # "fuubar") and names an RSpec formatter. Nothing else is evaluated.
    def self.formatter_class(name)
      return name if name.is_a?(Class) && formatter?(name)

      key = name.to_s
      built_in = BUILT_IN_FORMATTERS[key]
      return RSpec::Core::Formatters.const_get(built_in) if built_in

      unless CONSTANT_PATH =~ key
        raise Error,
          "Formatter '#{key}' unknown: use progress (p), documentation (d), json (j), " \
          "failures (f) or the class name of a formatter loaded with --require."
      end

      klass = resolve_constant(key)
      unless klass.is_a?(Class) && formatter?(klass)
        raise Error,
          "'#{key}' is not an RSpec formatter: it implements none of the RSpec formatter notifications."
      end

      klass
    end

    def self.formatter?(klass)
      return true if notifications_for(klass)

      FORMATTER_NOTIFICATIONS.any? { |notification| klass.method_defined?(notification) }
    end

    # The notifications a formatter class registered with RSpec (through any
    # ancestor), nil for classes RSpec does not know about.
    def self.notifications_for(klass)
      registry = RSpec::Core::Formatters::Loader.formatters
      notifications = Set.new
      klass.ancestors.each do |ancestor|
        registered = registry[ancestor]
        notifications.merge(registered) if registered
      end
      notifications.empty? ? nil : notifications
    end

    def self.resolve_constant(path)
      required = false
      begin
        path.sub(/\A::/, "").split("::").inject(Object) do |scope, part|
          raise NameError, "#{scope} is not a module" unless scope.is_a?(Module)

          scope.const_get(part, false)
        end
      rescue NameError => e
        unless required
          required = true
          retry if require_formatter(path)
        end
        raise Error, "Formatter '#{path}' could not be found (#{e.message}); load it with --require."
      end
    end

    def self.require_formatter(path)
      file = path.sub(/\A::/, "").gsub("::", "/").
        gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').
        gsub(/([a-z\d])([A-Z])/, '\1_\2').
        downcase.
        sub(%r{(\A|/)r_spec(/|\z)}, '\1rspec\2')
      require file
      true
    rescue LoadError
      false
    end

    # Number of examples `rspec --dry-run` finds for these files, or nil when
    # it cannot be determined. Used for formatters that need an accurate total
    # up front (Fuubar's progress bar).
    def self.count_examples(files, rspec_args = [], command: nil, env: {})
      argv = Array(command || rspec_command) +
        without_formatter_options(Array(rspec_args)) +
        ["--dry-run", "--format", "json"] +
        Array(files)
      stdout, _stderr, _status = Open3.capture3(env || {}, *argv)
      parse_example_count(stdout)
    rescue SystemCallError, IOError
      nil
    end

    def self.rspec_command
      executable = ENV["RSPEC_EXECUTABLE"]
      return executable.split if executable && !executable.strip.empty?

      [RbConfig.ruby, Gem.bin_path("rspec-core", "rspec")]
    rescue Gem::Exception, LoadError
      ["rspec"]
    end

    def self.without_formatter_options(args)
      kept = []
      skip_value = false
      args.each do |arg|
        if skip_value
          skip_value = false
        elsif %w[-f --format -o --out].include?(arg)
          skip_value = true
        elsif arg !~ /\A(?:--format=|--out=|-[fo].)/
          kept << arg
        end
      end
      kept
    end

    def self.parse_example_count(output)
      text = output.to_s.dup.force_encoding(Encoding::BINARY)
      start = text.rindex('{"version"')
      if start
        json = text[start..-1].force_encoding(Encoding::UTF_8).scrub
        count = begin
          summary = JSON.parse(json)["summary"]
          summary["example_count"] if summary.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
        return count if count.is_a?(Integer)
      end

      match = text.scan(/"example_count":(\d+)/).last
      match ? Integer(match[0]) : nil
    end

    def self.run_options_text(tags)
      inclusion, exclusion = filter_rules(tags)
      announcements = []
      announcements << "include #{RSpec::Core::InclusionRules.new(inclusion).description}" unless inclusion.empty?
      announcements << "exclude #{RSpec::Core::ExclusionRules.new(exclusion).description}" unless exclusion.empty?
      return nil if announcements.empty?

      if announcements.size == 1
        "Run options: #{announcements[0]}"
      else
        "Run options:\n  #{announcements.join("\n  ")}"
      end
    end

    def self.filter_rules(tags)
      tags = Array(tags)
      return [{}, {}] if tags.empty?

      options = RSpec::Core::Parser.parse(tags.flat_map { |tag| ["--tag", tag.to_s] })
      [options[:inclusion_filter] || {}, options[:exclusion_filter] || {}]
    end

    attr_reader :examples, :failed_examples, :pending_examples, :messages, :load_time,
                :errors_outside_of_examples_count, :worker_errors, :seed
    attr_writer :load_time
    attr_accessor :print_failed_group, :worker_files

    def initialize(start_time, seed, seed_used, out: $stdout, err: $stderr)
      @out = out
      @err = err
      @formatters = []
      @opened_outputs = []
      @listeners = {}
      @pending_examples = []
      @failed_examples = []
      @examples = []
      @examples_by_id = {}
      @messages = []
      @start_time = start_time
      @seed = seed
      @seed_used = seed_used ? true : false
      @load_time = 0
      @errors_outside_of_examples_count = 0
      @worker_errors = 0
      @worker_error_lines = []
      @failed_workers = Set.new
      @worker_attribution = false
      @config = {}
      @tags = []
      @announcements = Set.new
      @zero_examples_message = nil
      @loaded_examples = 0
      @reported_seed = nil
      @workers_used_seed = false
      @deprecation_keys = Set.new
      @profile_rows = []
      @profile_examples = nil
      @fail_fast = nil
      @print_failed_group = false
      @worker_files = nil
      @owner = nil
      @queues = {}
      @open_groups = {}
    end

    def add(name, outputs)
      formatter_class = self.class.formatter_class(name)
      Array(outputs).each do |output|
        @formatters << formatter_class.new(output)
      end
      @listeners.clear
      remove_instance_variable(:@message_fallback) if defined?(@message_fallback)
      remove_instance_variable(:@sequence_groups) if defined?(@sequence_groups)
    end

    def open_output(filename)
      dir = File.dirname(filename)
      FileUtils.mkdir_p(dir) unless File.directory?(dir)
      file = File.open(filename, "w")
      @opened_outputs << file
      file
    end

    # Tags given to the turbo_tests CLI (`-t focus`, `-t ~slow`); announced
    # once as "Run options: ..." like RSpec does.
    def run_options=(tags)
      @tags = Array(tags).map(&:to_s)
    end

    # `--profile[=N]` given to the turbo_tests CLI: true or an Integer.
    def profile_examples=(value)
      @profile_examples = value == true ? 10 : value
    end

    def fail_fast=(value)
      @fail_fast = value
    end

    # Borrowed from RSpec::Core::Reporter
    # https://github.com/rspec/rspec-core/blob/5699fcdc4723087ff6139af55bd155ad9ad61a7b/lib/rspec/core/reporter.rb#L71
    def report(run)
      start(run)
      begin
        yield self
      ensure
        finish
      end
    end

    # `run` is a Hash {workers:, pool:, files:, test_env_numbers:, tags:,
    # example_count:}, the v2 Array of file groups, or an expected example count.
    def start(run, time = RSpec::Core::Time.now)
      @start = time
      @load_time = (@start - @start_time).to_f
      @tags = Array(run[:tags]).map(&:to_s) if run.is_a?(Hash) && run.key?(:tags)

      expected_example_count = report_number_of_tests(run)
      announce_run_options

      start_seed = @seed_used ? @seed : (@config[:seed] || @seed)
      delegate(:seed, seed_notification(start_seed, @seed_used || random_order_configured?))
      delegate(:start, RSpec::Core::Notifications::StartNotification.new(expected_example_count, @load_time))
    end

    def report_number_of_tests(run)
      case run
      when Hash
        print_banner(run)
        run[:example_count]
      when Array
        num_processes = run.size
        num_tests = run.map(&:size).inject(0, :+)
        tests_per_process = (num_processes == 0 ? 0 : num_tests.to_f / num_processes).round
        @out.puts "#{num_processes} processes for #{num_tests} specs, ~ #{tests_per_process} specs per process"
        run.flatten(1).count
      else
        run
      end
    end

    # Entry point for rows coming from workers. Lifecycle rows are consumed by
    # the supervisor; anything else lands here. Returns :failure for a failed
    # example (the caller decides whether --fail-fast is met), nil otherwise.
    #
    # With a formatter that renders group nesting (documentation), the rows of
    # one worker's top-level group are shown together: the worker that starts
    # a group streams until it finishes it while other workers' rows wait.
    def handle(row)
      type = row[:type].to_s
      worker = row[:worker] || row[:process_id]

      if worker && SEQUENCED_ROWS.include?(type) && sequence_groups?
        sequence(worker, row)
      else
        process(row)
      end

      @out.flush if @out.respond_to?(:flush)
      type == "example_failed" ? :failure : nil
    end

    # The `config` row (RSpec configuration of the workers, before turbo_tests
    # adjusted it). May arrive 0..N times; the first non-nil value per key wins.
    def config(row)
      row.each do |key, value|
        next if key == :type || value.nil? || @config.key?(key)

        @config[key] = value
      end
      nil
    end

    def group_started(notification)
      delegate(:example_group_started, notification)
    end

    def group_finished(notification = nil)
      delegate(:example_group_finished, notification)
    end

    def example_passed(example)
      register_spec_file(example)
      delegate(:example_passed, example.notification)

      record(example)
    end

    def example_pending(example)
      register_spec_file(example)
      delegate(:example_pending, example.notification)

      record(example)
      @pending_examples << example
    end

    def example_failed(example)
      register_spec_file(example)
      delegate(:example_failed, example.notification)

      record(example)
      @failed_examples << example
    end

    def message(message)
      notification = RSpec::Core::Notifications::MessageNotification.new(message)
      delegate(:message, notification)
      message_fallback.message(notification) if message_fallback
      @messages << message
    end

    def error_outside_of_examples(error_message)
      @errors_outside_of_examples_count += 1
      message error_message
    end

    def deprecation(data)
      key = [data[:deprecated], data[:message], data[:call_site]]
      return nil if @deprecation_keys.include?(key)

      @deprecation_keys << key
      notification = RSpec::Core::Notifications::DeprecationNotification.from_hash(data)
      deprecation_formatter.deprecation(notification)
      delegate(:deprecation, notification)
      nil
    end

    # A worker was killed because it did not exit after finishing RSpec.
    def worker_hung(worker_id, files, diagnostics_text = nil, timeout = nil)
      after = timeout ? " #{format("%g", timeout)}s" : ""
      worker_error(
        worker_id,
        "Worker #{worker_id} did not exit#{after} after finishing RSpec; killed. Files: #{files_text(files)}",
        diagnostics_text
      )
    end

    # A worker exited before reporting `close` for its job.
    def worker_crashed(worker_id, files, status_text)
      worker_error(
        worker_id,
        "Worker #{worker_id} exited with status #{status_text} before finishing. Files: #{files_text(files)}",
        nil
      )
    end

    # One line per worker that failed (failed example, error outside of
    # examples, hung or crashed), with the files it ran in order. Without
    # worker ids on rows, every given group is assumed to have failed.
    def failed_group_lines(groups_by_worker)
      groups = groups_by_worker.to_a
      groups = groups.select { |worker, _files| @failed_workers.include?(worker) } if @worker_attribution
      groups.sort_by { |worker, _files| worker.to_s.rjust(10, "0") }.map do |worker, files|
        "Group that failed (worker #{worker}): #{Array(files).join(" ")}"
      end
    end

    # Also counts failures in rows still waiting to be shown.
    def success?
      @failed_examples.empty? && @errors_outside_of_examples_count.zero? && @worker_errors.zero? &&
        @queues.values.none? { |rows| rows.any? { |row| failure_row?(row) } }
    end

    def finish
      end_time = RSpec::Core::Time.now
      @duration = end_time - @start_time

      flush_sequenced
      announce_no_examples
      recap_worker_errors

      examples_notification = RSpec::Core::Notifications::ExamplesNotification.new(self)
      delegate(:stop, examples_notification)
      delegate(:start_dump, RSpec::Core::Notifications::NullNotification)
      delegate(:dump_pending, examples_notification)
      delegate(:dump_failures, examples_notification)
      deprecation_formatter.deprecation_summary(RSpec::Core::Notifications::NullNotification)
      delegate(:deprecation_summary, RSpec::Core::Notifications::NullNotification)
      dump_profile unless mute_profile_output?
      delegate(:dump_summary, summary_notification)
      delegate(:seed, seed_notification(@reported_seed || @seed, @workers_used_seed))
      print_failed_groups
    ensure
      delegate(:close, RSpec::Core::Notifications::NullNotification)
      @opened_outputs.each { |file| file.flush unless file.closed? }
    end

    protected

    def delegate(method, notification)
      @formatters.each do |formatter|
        formatter.__send__(method, notification) if listens?(formatter, method)
      end
    end

    private

    def process(row)
      worker = row[:worker] || row[:process_id]

      case row[:type].to_s
      when "example_passed"
        @worker_attribution = true if worker
        example_passed(FakeExample.from_obj(row[:example] || {}))
      when "example_pending"
        @worker_attribution = true if worker
        example_pending(FakeExample.from_obj(row[:example] || {}))
      when "example_failed"
        @worker_attribution = true if worker
        example_failed(FakeExample.from_obj(row[:example] || {}))
        @failed_workers << worker if worker
      when "group_started"
        group_started(group_notification(row[:group]))
      when "group_finished"
        group_finished(group_notification(row[:group]))
      when "load_summary"
        load_summary(row[:summary] || {})
      when "message"
        worker_message(row[:message].to_s, worker)
      when "deprecation"
        deprecation(row)
      when "dump_profile"
        @profile_rows << row
      when "seed"
        seed_reported(row)
      when "config"
        config(row)
      when *ROW_TYPES_WITHOUT_OUTPUT
        nil
      else
        @err.puts("Unhandled message in main process: #{row}")
      end
    end

    def failure_row?(row)
      case row[:type].to_s
      when "example_failed" then true
      when "message" then ERROR_OUTSIDE_OF_EXAMPLES =~ row[:message].to_s ? true : false
      else false
      end
    end

    def sequence_groups?
      return @sequence_groups if defined?(@sequence_groups)

      @sequence_groups = @formatters.any? do |formatter|
        %i[example_group_started example_group_finished].any? do |method|
          listens?(formatter, method) &&
            formatter.method(method).owner != RSpec::Core::Formatters::BaseFormatter
        end
      end
    end

    def sequence(worker, row)
      if @owner && @owner != worker
        (@queues[worker] ||= []) << row
      else
        show(worker, row)
        drain_queues
      end
    end

    def show(worker, row)
      process(row)
      open_groups = (@open_groups[worker] ||= [])
      case row[:type].to_s
      when "group_started" then open_groups.push(row[:group])
      when "group_finished" then open_groups.pop
      when "close" then close_open_groups(worker)
      end
      @owner = open_groups.empty? ? nil : worker
    end

    def drain_queues
      while @owner.nil? && !@queues.empty?
        worker, rows = @queues.first
        @queues.delete(worker)
        rows.each { |row| show(worker, row) }
      end
    end

    def close_open_groups(worker)
      open_groups = @open_groups[worker] || []
      group_finished(group_notification(open_groups.pop)) until open_groups.empty?
    end

    # A worker that sends nothing more must not hold the output.
    def release(worker)
      if @queues.key?(worker)
        @queues[worker] << { type: "close" }
      elsif @owner == worker
        close_open_groups(worker)
        @owner = nil
        drain_queues
      end
    end

    def flush_sequenced
      close_open_groups(@owner) if @owner
      @owner = nil
      until @queues.empty?
        worker, rows = @queues.first
        @queues.delete(worker)
        rows.each { |row| show(worker, row) }
        close_open_groups(worker)
        @owner = nil
      end
      @open_groups.each_key { |worker| close_open_groups(worker) }
    end

    def print_banner(run)
      workers = run[:workers].to_i
      files = run[:files]
      file_count = files.is_a?(Integer) ? files : Array(files).flatten.size
      pool = run[:pool] ? " (#{run[:pool]})" : ""
      @out.puts "#{pluralize(workers, "worker")}#{pool} for #{pluralize(file_count, "spec file")}"

      numbers = Array(run[:test_env_numbers])
      return if workers <= 1 || numbers.empty?

      @out.puts "TEST_ENV_NUMBER: #{numbers.map { |number| number.to_s.empty? ? '""' : number.to_s }.join(", ")}"
    end

    def pluralize(count, word)
      RSpec::Core::Formatters::Helpers.pluralize(count, word)
    end

    def listens?(formatter, method)
      notifications = @listeners.fetch(formatter.class) do
        @listeners[formatter.class] = self.class.notifications_for(formatter.class) || :respond_to
      end
      notifications == :respond_to ? formatter.respond_to?(method) : notifications.include?(method)
    end

    def any_listener?(method)
      @formatters.any? { |formatter| listens?(formatter, method) }
    end

    def message_fallback
      return @message_fallback if defined?(@message_fallback)

      @message_fallback =
        any_listener?(:message) ? nil : RSpec::Core::Formatters::FallbackMessageFormatter.new(@out)
    end

    def deprecation_formatter
      @deprecation_formatter ||= RSpec::Core::Formatters::DeprecationFormatter.new(@err, @out)
    end

    def record(example)
      @examples << example
      @examples_by_id[example.id] = example if example.id
    end

    # RSpec shows the failing line from the first backtrace frame in a loaded
    # spec file; nothing is loaded in this process, so register the files
    # examples come from.
    def register_spec_file(example)
      file = example.example_group && example.example_group.file_path
      return unless file

      configuration = RSpec.configuration
      return unless configuration.respond_to?(:loaded_spec_files)

      loaded = configuration.loaded_spec_files
      loaded << File.expand_path(file) if loaded.respond_to?(:<<)
    end

    def group_notification(group)
      RSpec::Core::Notifications::GroupNotification.new(FakeExampleGroup.from_obj(group))
    end

    def load_summary(summary)
      @loaded_examples += summary[:count].to_i
      load_time = summary[:load_time]
      @load_time = load_time.to_f if load_time && load_time.to_f > @load_time.to_f
    end

    def worker_message(text, worker)
      if text == NO_EXAMPLES_FOUND || text == ALL_FILTERED_OUT
        @zero_examples_message ||= text
      elsif RUN_OPTIONS =~ text || text.start_with?(ALL_FILTERED_OUT)
        announce(text)
      elsif ERROR_OUTSIDE_OF_EXAMPLES =~ text
        @failed_workers << worker if worker
        error_outside_of_examples(text)
      else
        message(text)
      end
    end

    def announce(text)
      return if silenced? || @announcements.include?(text)

      @announcements << text
      message(text)
    end

    def announce_run_options
      text = self.class.run_options_text(@tags)
      announce(text) if text
    end

    def announce_no_examples
      return if silenced?
      return unless @examples.empty? && @loaded_examples.zero?
      return unless @errors_outside_of_examples_count.zero? && @worker_errors.zero?

      text = @zero_examples_message
      unless text
        inclusion, exclusion = self.class.filter_rules(@tags)
        if inclusion.empty? && exclusion.empty?
          text = NO_EXAMPLES_FOUND
        elsif inclusion.empty? || exclusion.empty?
          text = ALL_FILTERED_OUT
        end
      end
      message(text) if text
    end

    def silenced?
      @config[:silence_filter_announcements] == true
    end

    def random_order_configured?
      @config[:order].to_s == "random"
    end

    def seed_reported(row)
      return unless row[:seed_used]

      @workers_used_seed = true
      @reported_seed = row[:seed] if @reported_seed.nil?
    end

    def seed_notification(seed, used)
      RSpec::Core::Notifications::SeedNotification.new(seed, used && !seed.nil?)
    end

    def worker_error(worker_id, line, details)
      @worker_errors += 1
      @worker_error_lines << line
      @failed_workers << worker_id
      @err.puts(line)
      @err.puts(details) if details && !details.to_s.empty?
      @err.flush if @err.respond_to?(:flush)
      release(worker_id)
    end

    def files_text(files)
      Array(files).join(" ")
    end

    def recap_worker_errors
      return if @worker_error_lines.empty?

      message("\nWorker errors:\n#{@worker_error_lines.map { |line| "  #{line}" }.join("\n")}")
    end

    def profile_number_of_examples
      [@profile_examples, @config[:profile_examples]].each do |value|
        return 10 if value == true
        return value.to_i if value.is_a?(Integer) && value > 0
      end
      counts = @profile_rows.map { |row| row[:number_of_examples].to_i }
      counts.max unless counts.empty?
    end

    def fail_fast_limit_met?
      fail_fast = @fail_fast.nil? ? @config[:fail_fast] : @fail_fast
      return false unless fail_fast

      fail_fast == true ? @failed_examples.any? : fail_fast.to_i <= @failed_examples.size
    end

    def mute_profile_output?
      number = profile_number_of_examples
      number.nil? || number <= 0 || fail_fast_limit_met?
    end

    # One ProfileNotification for the whole run built from the per-job top N
    # lists, so RSpec's own ranking and formatting apply unchanged.
    def dump_profile
      examples = {}
      groups = {}
      duration = 0.0

      @profile_rows.each do |row|
        duration += row[:duration].to_f
        Array(row[:slowest_examples]).each do |entry|
          key = entry[:id] || entry[:location]
          next if examples.key?(key)

          example = @examples_by_id[entry[:id]] || profile_example(entry)
          examples[key] = example if example.execution_result.run_time
        end
        Array(row[:slowest_groups]).each do |entry|
          stats = groups[entry[:location]] ||= { count: 0, total_time: 0.0, description: entry[:description] }
          stats[:count] += entry[:count].to_i
          stats[:total_time] += entry[:total_time].to_f
        end
      end

      duration = @duration.to_f unless duration > 0
      example_groups = {}
      groups.each do |location, stats|
        group = FakeExampleGroup.new(description: stats[:description].to_s, location: location)
        example_groups[group] = stats
      end

      notification = RSpec::Core::Notifications::ProfileNotification.new(
        duration, examples.values, profile_number_of_examples, example_groups
      )

      if any_listener?(:dump_profile)
        delegate(:dump_profile, notification)
      else
        RSpec::Core::Formatters::ProfileFormatter.new(@out).dump_profile(notification)
      end
    end

    def profile_example(entry)
      FakeExample.from_obj(
        id: entry[:id],
        description: entry[:description],
        full_description: entry[:full_description],
        location: entry[:location],
        run_time: entry[:run_time] && entry[:run_time].to_f,
        execution_result: { status: "passed" }
      )
    end

    def summary_notification
      summary = Summary.new(
        @duration,
        @examples,
        @failed_examples,
        @pending_examples,
        @load_time,
        @errors_outside_of_examples_count
      )
      summary.worker_errors_count = @worker_errors
      summary
    end

    def print_failed_groups
      return unless @print_failed_group && @worker_files

      failed_group_lines(@worker_files).each { |line| @out.puts(line) }
    end
  end
end
