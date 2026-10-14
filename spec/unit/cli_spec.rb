require "tmpdir"

RSpec.describe TurboTests::CLI do
  def parse(*argv)
    described_class.new(argv).parse
  end

  around do |example|
    begin
      saved = ENV.select { |key, _| key == "PARALLEL_TEST_PROCESSORS" }
      ENV.delete("PARALLEL_TEST_PROCESSORS")
      example.run
    ensure
      ENV.delete("PARALLEL_TEST_PROCESSORS")
      ENV.update(saved)
    end
  end

  it "defaults to the number of processors, progress on stdout and the default pool" do
    options = parse

    expect(options.workers).to eq(Etc.nprocessors)
    expect(options.formatters).to eq([{name: "progress", outputs: ["-"]}])
    expect(options.files).to eq([])
    expect(options.pool).to eq(:auto)
    expect(options.exit_timeout).to eq(60.0)
    expect(options.rake_hooks).to be(true)
    expect(options.record_runtime).to be_nil
    expect(options.first_is_1).to be_nil
  end

  it "honours PARALLEL_TEST_PROCESSORS" do
    ENV["PARALLEL_TEST_PROCESSORS"] = "3"

    expect(parse.workers).to eq(3)
  end

  it "accepts -n, -w and --workers" do
    expect(parse("-n", "2").workers).to eq(2)
    expect(parse("-w", "5").workers).to eq(5)
    expect(parse("--workers=7").workers).to eq(7)
    expect { parse("-n", "0") }.to raise_error(OptionParser::InvalidArgument)
  end

  it "ignores a leading rspec token (flatware-style invocation)" do
    options = parse("rspec", "-w", "8", "spec/models")

    expect(options.workers).to eq(8)
    expect(options.files).to eq(["spec/models"])
  end

  it "passes everything after -- to rspec verbatim and a second -- to files" do
    options = parse("spec/a_spec.rb", "--", "--tag", "~slow", "-e", "foo bar", "--", "spec/b_spec.rb")

    expect(options.files).to eq(["spec/a_spec.rb", "spec/b_spec.rb"])
    expect(options.rspec_args).to eq(["--tag", "~slow", "-e", "foo bar"])
  end

  it "splits --test-options like parallel_rspec" do
    options = parse("--test-options", "--tag focus -e 'two words'")

    expect(options.rspec_args).to eq(["--tag", "focus", "-e", "two words"])
  end

  it "parses fail-fast with and without a count" do
    expect(parse("--fail-fast").fail_fast).to eq(1)
    expect(parse("--fail-fast=3").fail_fast).to eq(3)
    expect(parse("--fail-fast=0").fail_fast).to eq(1)
  end

  it "parses profile with and without a count" do
    expect(parse("--profile").profile).to eq(10)
    expect(parse("--profile=3").profile).to eq(3)
  end

  it "parses scheduling options" do
    options = parse("--group-by", "filesize", "--only-group", "1,3", "--groups", "4", "--static")

    expect(options.group_by).to eq(:filesize)
    expect(options.only_group).to eq([1, 3])
    expect(options.groups).to eq(4)
    expect(options.static).to be(true)
    expect { parse("--group-by", "nope") }.to raise_error(OptionParser::InvalidArgument)
    expect { parse("--only-group", "0") }.to raise_error(OptionParser::InvalidArgument)
  end

  it "parses pool, lifecycle and runtime options" do
    options = parse("--pool", "spawn", "--exit-timeout", "0", "--diagnose", "--nice", "--preload", "spec/preload.rb",
      "--runtime-log", "tmp/x.log", "--no-runtime-log", "--first-is-1", "--no-rake-hooks", "--print-failed-group")

    expect(options.pool).to eq(:spawn)
    expect(options.exit_timeout).to eq(0.0)
    expect(options.diagnose).to be(true)
    expect(options.nice).to be(true)
    expect(options.preload).to eq("spec/preload.rb")
    expect(options.runtime_log).to eq("tmp/x.log")
    expect(options.record_runtime).to be(false)
    expect(options.first_is_1).to be(true)
    expect(options.rake_hooks).to be(false)
    expect(options.print_failed_group).to be(true)
    expect(parse("--first-is-blank").first_is_1).to be(false)
    expect(parse("--record-runtime").record_runtime).to be(true)
    expect { parse("--pool", "threads") }.to raise_error(OptionParser::InvalidArgument)
  end

  it "parses discovery options" do
    options = parse("--pattern", "spec/**/*_test.rb", "--exclude-pattern", "spec/slow/**", "--default-path", "test")

    expect(options.pattern).to eq("spec/**/*_test.rb")
    expect(options.exclude_pattern).to eq("spec/slow/**")
    expect(options.default_path).to eq("test")
  end

  it "implements --next-failure like rspec" do
    options = parse("--next-failure")

    expect(options.only_failures).to be(true)
    expect(options.next_failure).to be(true)
    expect(options.fail_fast).to eq(1)
    expect(options.order).to eq("defined")
  end

  it "keeps seed, order and tags" do
    options = parse("--seed", "1234", "--order", "rand", "-t", "focus", "--tag", "~slow")

    expect(options.seed).to eq("1234")
    expect(options.order).to eq("rand")
    expect(options.tags).to eq(["focus", "~slow"])
    expect { parse("--seed", "abc") }.to raise_error(ArgumentError)
  end

  it "attaches -o to the last formatter and creates progress when none was given" do
    expect(parse("-o", "out.txt").formatters).to eq([{name: "progress", outputs: ["out.txt"]}])
    expect(parse("-f", "d", "-o", "a.txt", "-f", "p").formatters)
      .to eq([{name: "d", outputs: ["a.txt"]}, {name: "p", outputs: ["-"]}])
  end

  it "maps the 2.x Runner.run hash onto Options" do
    options = TurboTests::Options.from_hash(
      formatters: [{name: "d", outputs: ["-"]}], tags: ["focus"], files: ["spec/a_spec.rb"], runtime_log: "x.log",
      verbose: true, fail_fast: 2, count: 3, seed: 42
    )

    expect(options.formatters).to eq([{name: "d", outputs: ["-"]}])
    expect(options.tags).to eq(["focus"])
    expect(options.files).to eq(["spec/a_spec.rb"])
    expect(options.runtime_log).to eq("x.log")
    expect(options.verbose).to be(true)
    expect(options.fail_fast).to eq(2)
    expect(options.workers).to eq(3)
    expect(options.seed).to eq("42")
    expect { TurboTests::Options.from_hash(use_runtime_info: true) }.to output(/ignoring unknown option :use_runtime_info/).to_stderr
  end

  it "rejects unknown options before --" do
    expect { parse("--frobnicate") }.to raise_error(OptionParser::InvalidOption)
  end

  def in_tmp_project(prefix)
    root = File.expand_path("../../tmp", __dir__)
    FileUtils.mkdir_p(root)
    dir = Dir.mktmpdir(prefix, root)
    original = Dir.pwd
    Dir.chdir(dir)
    yield
  ensure
    Dir.chdir(original) if original
    FileUtils.rm_rf(dir) if dir
  end

  context "with parallel_tests option files" do
    around { |example| in_tmp_project("cli") { example.run } }

    it "uses .rspec_parallel through --options unless the user passed --options" do
      File.write(".rspec_parallel", "--tag focus\n")
      FileUtils.mkdir_p("spec")
      File.write("spec/parallel_spec.opts", "--tag other\n")

      expect(parse.rspec_args).to eq(["--options", ".rspec_parallel"])
      expect(parse("--", "-O", "custom").rspec_args).to eq(["-O", "custom"])
    end

    it "falls back to spec/parallel_spec.opts and spec/spec.opts" do
      FileUtils.mkdir_p("spec")
      File.write("spec/spec.opts", "--tag old\n")

      expect(parse.rspec_args).to eq(["--options", "spec/spec.opts"])
    end
  end

  describe "rake hooks" do
    around { |example| in_tmp_project("rake") { example.run } }

    before do
      require "rake"
      Rake.application = Rake::Application.new
    end

    let(:options) { TurboTests::Options.new }

    def write_rakefile(log)
      File.write("Rakefile", <<~RUBY)
        namespace :turbo_tests do
          task(:setup) { File.write(#{log.inspect}, "setup ARGV=\#{ARGV.inspect}\\n") }
          task(:cleanup) { File.open(#{log.inspect}, "a") { |f| f.puts "cleanup" } }
        end
      RUBY
    end

    it "runs setup before and cleanup after the block with an isolated ARGV" do
      begin
        log = File.expand_path("hooks.log")
        write_rakefile(log)
        ARGV.replace(["--should-not-leak"])

        status = TurboTests::CLI::RakeHooks.new(options).around do
          File.open(log, "a") { |f| f.puts "run" }
          3
        end

        expect(status).to eq(3)
        expect(File.read(log)).to eq("setup ARGV=[]\nrun\ncleanup\n")
        expect(ARGV).to eq(["--should-not-leak"])
      ensure
        ARGV.replace([])
      end
    end

    it "does not load Rakefiles that never mention turbo_tests" do
      File.write("Rakefile", "raise 'must not be loaded'\n")

      expect(TurboTests::CLI::RakeHooks.new(options).around { 0 }).to eq(0)
    end

    it "warns and continues when the Rakefile cannot be loaded" do
      File.write("Rakefile", "# turbo_tests\nraise 'broken'\n")

      expect {
        expect(TurboTests::CLI::RakeHooks.new(options).around { 0 }).to eq(0)
      }.to output(/skipping rake hooks.*broken/).to_stderr
    end

    it "is disabled by --no-rake-hooks" do
      log = File.expand_path("hooks.log")
      write_rakefile(log)
      options.rake_hooks = false

      expect(TurboTests::CLI::RakeHooks.new(options).around { 0 }).to eq(0)
      expect(File.exist?(log)).to be(false)
    end
  end
end
