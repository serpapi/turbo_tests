require "tmpdir"

RSpec.describe TurboTests::EnvNumber do
  # Rails double whose database configuration is evaluated on every call, like
  # Rails.application.config.database_configuration (ERB in database.yml).
  def fake_rails(&block)
    config = Object.new
    config.define_singleton_method(:database_configuration, &block)
    application = Struct.new(:config).new(config)
    Struct.new(:application, :root).new(application, Dir.pwd)
  end

  def per_worker_rails(adapter: "postgresql")
    fake_rails { {"test" => {"adapter" => adapter, "database" => "app_test#{ENV["TEST_ENV_NUMBER"]}"}} }
  end

  def fake_active_record(connect: nil)
    calls = []
    active_record = Module.new
    no_database = Class.new(StandardError)
    active_record.const_set(:NoDatabaseError, no_database)
    base = Class.new do
      class << self
        attr_accessor :configurations
      end
    end
    base.define_singleton_method(:calls) { calls }
    base.define_singleton_method(:establish_connection) { |config| calls << [self, :establish_connection, config] }
    base.define_singleton_method(:remove_connection) { calls << [self, :remove_connection] }
    base.define_singleton_method(:abstract_class=) { |value| calls << [self, :abstract_class, value] }
    connection = Object.new
    connection.define_singleton_method(:execute) do |sql|
      calls << [:execute, sql]
      connect&.call(no_database)
    end
    base.define_singleton_method(:connection) { connection }
    active_record.const_set(:Base, base)
    active_record
  end

  around do |example|
    saved = ENV.to_h.slice("TEST_ENV_NUMBER", "PARALLEL_TEST_FIRST_IS_1")
    ENV.delete("PARALLEL_TEST_FIRST_IS_1")
    ENV.delete("TEST_ENV_NUMBER")
    example.run
  ensure
    %w[TEST_ENV_NUMBER PARALLEL_TEST_FIRST_IS_1].each { |key| ENV.delete(key) }
    ENV.update(saved)
  end

  describe ".forced / .detect" do
    it "honours --first-is-1, --first-is-blank and PARALLEL_TEST_FIRST_IS_1" do
      expect(described_class.forced(true)).to eq("1")
      expect(described_class.forced(false)).to eq("")
      expect(described_class.forced(nil)).to be_nil
      ENV["PARALLEL_TEST_FIRST_IS_1"] = "true"
      expect(described_class.forced(nil)).to eq("1")
    end

    it "probes only when nothing forces the convention" do
      probe = -> { "probed" }

      expect(described_class.detect(TurboTests::Options.new(first_is_1: true), probe: probe)).to eq("1")
      expect(described_class.detect(TurboTests::Options.new(first_is_1: false), probe: probe)).to eq("")
      expect(described_class.detect(TurboTests::Options.new, probe: probe)).to eq("probed")
    end

    it "numbers workers 2..N" do
      expect(described_class.numbers("", 3)).to eq(["", "2", "3"])
      expect(described_class.numbers("1", 2)).to eq(["1", "2"])
    end
  end

  describe ".probe" do
    it "is blank without Rails and ActiveRecord" do
      expect(described_class.probe(rails: nil, active_record: nil)).to eq("")
      expect(described_class.probe(rails: per_worker_rails, active_record: nil)).to eq("")
    end

    it "is blank without connecting when the configuration ignores TEST_ENV_NUMBER" do
      active_record = fake_active_record
      rails = fake_rails { {"test" => {"adapter" => "postgresql", "database" => "app_test"}} }

      expect(described_class.probe(rails: rails, active_record: active_record)).to eq("")
      expect(active_record::Base.calls).to eq([])
    end

    it "is 1 when the ...1 database exists (turbo_tests 2.x provisioning), connecting through its own class" do
      active_record = fake_active_record
      ENV["TEST_ENV_NUMBER"] = "7"

      expect(described_class.probe(rails: per_worker_rails, active_record: active_record)).to eq("1")

      probe_class = described_class::ProbeRecord
      expect(probe_class.superclass).to equal(active_record::Base)
      expect(active_record::Base.calls).to eq([
        [probe_class, :abstract_class, true],
        [probe_class, :establish_connection, {"adapter" => "postgresql", "database" => "app_test1"}],
        [:execute, "SELECT 1"],
        [probe_class, :remove_connection]
      ])
      expect(ENV["TEST_ENV_NUMBER"]).to eq("7")
    end

    it "is blank when the ...1 database does not exist" do
      active_record = fake_active_record(connect: ->(no_database) { raise no_database, "database app_test1 does not exist" })

      expect(described_class.probe(rails: per_worker_rails, active_record: active_record)).to eq("")
      expect(ENV.key?("TEST_ENV_NUMBER")).to be(false)
    end

    it "aborts on any other error instead of guessing" do
      active_record = fake_active_record(connect: ->(_) { raise IOError, "connection refused" })

      expect { described_class.probe(rails: per_worker_rails, active_record: active_record) }
        .to raise_error(described_class::Ambiguous, "Cannot determine the TEST_ENV_NUMBER convention (IOError: connection refused). " \
          "Pass --first-is-1 or --first-is-blank (or PARALLEL_TEST_FIRST_IS_1=true).")
    end

    it "aborts when the configuration cannot be evaluated" do
      rails = fake_rails { raise KeyError, "DATABASE_URL" }

      expect { described_class.probe(rails: rails, active_record: fake_active_record) }
        .to raise_error(described_class::Ambiguous, /KeyError: DATABASE_URL/)
    end

    it "uses the primary database of multi-database configurations" do
      active_record = fake_active_record
      rails = fake_rails do
        {"test" => {"primary" => {"adapter" => "mysql2", "database" => "app_test#{ENV["TEST_ENV_NUMBER"]}"},
                    "cache" => {"adapter" => "mysql2", "database" => "cache_test"}}}
      end

      expect(described_class.probe(rails: rails, active_record: active_record)).to eq("1")
      expect(active_record::Base.calls).to include([described_class::ProbeRecord, :establish_connection, {"adapter" => "mysql2", "database" => "app_test1"}])
    end

    it "checks sqlite files instead of connecting (connecting would create them)" do
      active_record = fake_active_record
      root = File.expand_path("../../tmp", __dir__)
      FileUtils.mkdir_p(root)
      Dir.mktmpdir("sqlite", root) do |dir|
        rails = fake_rails { {"test" => {"adapter" => "sqlite3", "database" => File.join(dir, "test#{ENV["TEST_ENV_NUMBER"]}.sqlite3")}} }

        expect(described_class.probe(rails: rails, active_record: active_record)).to eq("")
        File.write(File.join(dir, "test1.sqlite3"), "")
        expect(described_class.probe(rails: rails, active_record: active_record)).to eq("1")
        expect(active_record::Base.calls).to eq([])
      end
    end
  end

  describe "default fork hooks" do
    it "re-reads the database configuration after TEST_ENV_NUMBER is set in the worker" do
      active_record = fake_active_record
      rails = per_worker_rails
      ENV["TEST_ENV_NUMBER"] = ""
      preloaded = rails.application.config.database_configuration

      ENV["TEST_ENV_NUMBER"] = "3"
      TurboTests::Hooks.reestablish_active_record(rails: rails, active_record: active_record)

      expect(preloaded["test"]["database"]).to eq("app_test")
      expect(active_record::Base.configurations).to eq("test" => {"adapter" => "postgresql", "database" => "app_test3"})
      expect(active_record::Base.calls).to eq([[active_record::Base, :establish_connection, :test]])
    end

    it "runs SimpleCov's at_fork with the worker number when coverage is running" do
      at_fork = []
      simplecov = Struct.new(:running, :at_fork).new(true, ->(number) { at_fork << number })

      TurboTests::Hooks.default_after_fork(4, rails: nil, active_record: nil, simplecov: simplecov)

      expect(at_fork).to eq([4])
    end

    def handler_double(&clear)
      handler = Object.new
      handler.define_singleton_method(:clear_all_connections!, &clear)
      active_record = Module.new
      base = Class.new
      base.define_singleton_method(:connection_handler) { handler }
      active_record.const_set(:Base, base)
      active_record
    end

    it "disconnects every pool before forking, passing :all when the handler takes a role" do
      calls = []
      TurboTests::Hooks.default_before_fork(active_record: handler_double { |role = nil| calls << role })
      TurboTests::Hooks.default_before_fork(active_record: handler_double { calls << :no_arguments })
      TurboTests::Hooks.default_before_fork(active_record: handler_double { |role = nil|
        raise ArgumentError, "unknown role" if role
        calls << :fallback
      })

      expect(calls).to eq([:all, :no_arguments, :fallback])
    end

    it "runs user hooks after the defaults and can drop the defaults" do
      hooks = TurboTests::Hooks.new
      seen = []
      hooks.after_fork { |number| seen << number }
      hooks.default_hooks = false
      hooks.run_after_fork(2)

      expect(seen).to eq([2])
    end
  end
end
