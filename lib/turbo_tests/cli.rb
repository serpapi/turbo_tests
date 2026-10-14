# frozen_string_literal: true

require "optparse"
require "shellwords"
require "etc"

module TurboTests
  class CLI
    PARALLEL_OPTS_FILES = [".rspec_parallel", "spec/parallel_spec.opts", "spec/spec.opts"].freeze

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      options = begin
        parse
      rescue OptionParser::ParseError => e
        warn "turbo_tests: #{e.message}"
        warn "Run `turbo_tests --help` for usage."
        exit 1
      end

      options.requires.each { |f| require(f) }

      exitstatus = begin
        RakeHooks.new(options).around { TurboTests::Runner.run(options) }
      rescue TurboTests::Error => e
        warn "turbo_tests: #{e.message}"
        1
      end

      # From https://github.com/serpapi/turbo_tests/pull/20/
      exit exitstatus
    end

    # Builds Options from argv without side effects (no requires, no exit).
    def parse
      options = Options.new(start_time: RSpec::Core::Time.now)
      argv, passthrough = split_passthrough(@argv)
      argv.shift if argv.first == "rspec"

      parser(options).parse!(argv)

      options.files = argv + passthrough[:files]
      options.rspec_args = parallel_opts_args(passthrough[:args]) + passthrough[:args]
      options.rspec_args.concat(Shellwords.split(options.test_options)) if options.test_options
      options.workers ||= default_workers
      finalize_formatters(options)
      options
    end

    private

    def split_passthrough(argv)
      index = argv.index("--")
      return [argv, {args: [], files: []}] unless index

      rest = argv[(index + 1)..-1]
      files_index = rest.index("--")
      if files_index
        [argv[0...index], {args: rest[0...files_index], files: rest[(files_index + 1)..-1]}]
      else
        [argv[0...index], {args: rest, files: []}]
      end
    end

    def parser(options)
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Run RSpec in parallel workers, giving each ENV['TEST_ENV_NUMBER'] ('', '2', '3', ...).

          Reports test results incrementally. Source code of `turbo_tests` gem is based on Discourse and RubyGems work in this area (see README file of the source repository).

          Usage: turbo_tests [options] [files or directories] [-- rspec options [-- files]]

          [optional] Only selected files & folders:
            turbo_tests spec/bar spec/baz/xxx_spec.rb

          Options:
        BANNER

        opts.on("-n", "-w", "--workers N", Integer, "How many workers to use, default: PARALLEL_TEST_PROCESSORS or available CPUs") do |n|
          raise OptionParser::InvalidArgument, "workers must be >= 1" if n < 1

          options.workers = n
        end

        opts.on("-r", "--require PATH", "Require a file in the parent process (e.g. a custom formatter).") do |filename|
          options.requires << filename
        end

        opts.on("-f", "--format FORMATTER", "Choose a formatter: progress (p), documentation (d), or a formatter class loaded with -r. Default: progress") do |name|
          options.formatters << {name: name, outputs: []}
        end

        opts.on("-o", "--out FILE", "Write output to a file instead of $stdout") do |filename|
          options.formatters << {name: "progress", outputs: []} if options.formatters.empty?
          options.formatters.last[:outputs] << filename
        end

        opts.on("-t", "--tag TAG", "Run examples with the specified tag.") do |tag|
          options.tags << tag
        end

        opts.on("--seed SEED", "Seed for rspec (forces random order, as in rspec)") do |seed|
          options.seed = Integer(seed).to_s
        end

        opts.on("--order TYPE", "Forwarded to rspec: defined, rand[:SEED], random[:SEED], recently-modified") do |order|
          options.order = order
        end

        opts.on("--fail-fast=[N]", "Stop dispatching and interrupt workers after N failures (default 1)") do |n|
          n = begin
            Integer(n)
          rescue ArgumentError, TypeError
            nil
          end
          options.fail_fast = n.nil? || n < 1 ? 1 : n
        end

        opts.on("--pattern PATTERN", "Load files matching pattern (rspec --pattern)") do |pattern|
          options.pattern = pattern
        end

        opts.on("--exclude-pattern PATTERN", "Skip files matching pattern (rspec --exclude-pattern)") do |pattern|
          options.exclude_pattern = pattern
        end

        opts.on("--default-path PATH", "Directory used when no files are given (rspec --default-path)") do |path|
          options.default_path = path
        end

        opts.on("--group-by TYPE", [:runtime, :filesize, :found], "Weights for scheduling: runtime (default), filesize, found") do |type|
          options.group_by = type
        end

        opts.on("--only-group LIST", Array, "Split files into static groups and run only these (1-based, e.g. 2,3)") do |list|
          options.only_group = list.map { |item| Integer(item) }
          raise OptionParser::InvalidArgument, "groups are 1-based" if options.only_group.any? { |g| g < 1 }
        end

        opts.on("--groups N", Integer, "Number of static groups (default: number of workers)") do |n|
          raise OptionParser::InvalidArgument, "groups must be >= 1" if n < 1

          options.groups = n
        end

        opts.on("--runtime-log FILE", "Location of previously recorded test runtimes") do |filename|
          options.runtime_log = filename
        end

        opts.on("--no-runtime-log", "Do not record runtimes after the run") do
          options.record_runtime = false
        end

        opts.on("--record-runtime", "Record runtimes after the run (default)") do
          options.record_runtime = true
        end

        opts.on("--first-is-1", "First worker gets TEST_ENV_NUMBER=1 (default: auto-detect)") do
          options.first_is_1 = true
        end

        opts.on("--first-is-blank", "First worker gets TEST_ENV_NUMBER='' (default: auto-detect)") do
          options.first_is_1 = false
        end

        opts.on("--nice", "Run workers with lower CPU priority") do
          options.nice = true
        end

        opts.on("--preload FILE", "File the fork preloader requires before forking (default: .rspec --require files)") do |file|
          options.preload = file
        end

        opts.on("--pool TYPE", [:auto, :fork, :spawn, :command], "Worker pool: auto (default), fork, spawn, command") do |pool|
          options.pool = pool
        end

        opts.on("--static", "Split files into one static group per worker (2.x scheduling)") do
          options.static = true
        end

        opts.on("--exit-timeout SECONDS", Float, "Kill workers that do not exit SECONDS after finishing (default 60, 0 = wait forever)") do |seconds|
          raise OptionParser::InvalidArgument, "exit timeout must be >= 0" if seconds < 0

          options.exit_timeout = seconds
        end

        opts.on("--diagnose", "Collect extra diagnostics (perf/bpftrace when available) for hung workers") do
          options.diagnose = true
        end

        opts.on("--print-failed-group", "Print the files run by each worker that had a failure") do
          options.print_failed_group = true
        end

        opts.on("--profile=[N]", "Show the N slowest examples and groups (default 10)") do |n|
          n = begin
            Integer(n)
          rescue ArgumentError, TypeError
            nil
          end
          options.profile = n.nil? || n < 1 ? 10 : n
        end

        opts.on("--only-failures", "Run only examples that failed last time (rspec --only-failures)") do
          options.only_failures = true
        end

        opts.on("--next-failure", "rspec --next-failure: --only-failures --fail-fast --order defined") do
          options.next_failure = true
          options.only_failures = true
          options.fail_fast ||= 1
          options.order ||= "defined"
        end

        opts.on("-v", "--verbose", "More output") do
          options.verbose = true
        end

        opts.on("--test-options OPTIONS", "Extra rspec options as one string (parallel_rspec compatible)") do |test_options|
          options.test_options = test_options
        end

        opts.on("--no-rake-hooks", "Do not run turbo_tests:setup / turbo_tests:cleanup rake tasks") do
          options.rake_hooks = false
        end

        opts.on("--version", "Print version") do
          puts TurboTests::VERSION
          exit 0
        end

        opts.on_tail("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end
      end
    end

    def parallel_opts_args(rspec_args)
      return [] if rspec_args.any? { |arg| arg == "-O" || arg.start_with?("--options") || arg =~ /\A-O./ }

      file = PARALLEL_OPTS_FILES.detect { |f| File.file?(f) }
      file ? ["--options", file] : []
    end

    def default_workers
      from_env = ENV["PARALLEL_TEST_PROCESSORS"].to_s
      return from_env.to_i if from_env =~ /\A\s*\d+\s*\z/ && from_env.to_i > 0

      Etc.nprocessors
    end

    def finalize_formatters(options)
      options.formatters << {name: "progress", outputs: []} if options.formatters.empty?
      options.formatters.each do |formatter|
        formatter[:outputs] << "-" if formatter[:outputs].empty?
      end
    end

    # Runs the `turbo_tests:setup` / `turbo_tests:cleanup` rake tasks around
    # the run when the project defines them (adopted from serpapi/turbo_tests#82).
    class RakeHooks
      RAKEFILES = ["rakefile", "Rakefile", "rakefile.rb", "Rakefile.rb"].freeze
      SETUP = "turbo_tests:setup"
      CLEANUP = "turbo_tests:cleanup"

      def initialize(options)
        @options = options
        @warned = false
        @loaded = false
      end

      def around
        return yield unless @options.rake_hooks

        @rakefile = find_rakefile
        return yield unless @rakefile && mentions_turbo_tests?(@rakefile)

        begin
          invoke(SETUP)
        rescue SystemExit => e
          warn "turbo_tests: #{SETUP} exited with status #{e.status}"
          return e.status.zero? ? 1 : e.status
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise if e.is_a?(Interrupt)

          warn "turbo_tests: #{SETUP} failed: #{e.class}: #{e.message}"
          return 1
        end

        status = yield

        begin
          invoke(CLEANUP)
        rescue SystemExit => e
          status = [status, e.status].max
        rescue Exception => e # rubocop:disable Lint/RescueException
          raise if e.is_a?(Interrupt)

          warn "turbo_tests: #{CLEANUP} failed: #{e.class}: #{e.message}"
          status = [status, 1].max
        end
        status
      end

      private

      def find_rakefile
        dir = Dir.pwd
        loop do
          RAKEFILES.each do |name|
            path = File.join(dir, name)
            return path if File.file?(path)
          end
          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      # Loading a Rakefile can boot a whole application; only pay for it when
      # the project mentions turbo_tests in its rake files.
      def mentions_turbo_tests?(rakefile)
        root = File.dirname(rakefile)
        candidates = [rakefile] +
          Dir[File.join(root, "rakelib", "**", "*.rake")] +
          Dir[File.join(root, "lib", "tasks", "**", "*.rake")]
        candidates.any? do |file|
          begin
            File.read(file).include?("turbo_tests")
          rescue SystemCallError, IOError
            false
          end
        end
      end

      def invoke(name)
        return unless load_rake
        return unless Rake::Task.task_defined?(name)

        saved_argv = ARGV.dup
        ARGV.replace([])
        in_rakefile_dir { Rake::Task[name].invoke }
      ensure
        ARGV.replace(saved_argv) if saved_argv
      end

      def load_rake
        return @rake_ok if @loaded

        @loaded = true
        @rake_ok = false
        saved_argv = ARGV.dup
        begin
          require "rake"
          ARGV.replace([])
          app = Rake.application
          app.init("rake")
          app.options.silent = true if app.options.respond_to?(:silent=)
          in_rakefile_dir do
            app.respond_to?(:raw_load_rakefile) ? app.raw_load_rakefile : app.load_rakefile
          end
          @rake_ok = true
        rescue StandardError, ScriptError, SystemExit => e
          warn_once("turbo_tests: skipping rake hooks (#{e.class}: #{e.message})")
        ensure
          ARGV.replace(saved_argv)
        end
        @rake_ok
      end

      # Rake chdirs to the Rakefile's directory; keep that local to the hook.
      def in_rakefile_dir
        original_dir = Dir.pwd
        Dir.chdir(File.dirname(@rakefile))
        yield
      ensure
        Dir.chdir(original_dir) if original_dir && Dir.pwd != original_dir
      end

      def warn_once(message)
        return if @warned

        @warned = true
        warn message
      end
    end
  end
end
