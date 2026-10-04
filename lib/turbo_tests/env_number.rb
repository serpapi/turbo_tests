# frozen_string_literal: true

module TurboTests
  # Decides the first worker's TEST_ENV_NUMBER ("" or "1"); workers 2..N
  # always get "2".."N".
  #
  # Forced by --first-is-1 / PARALLEL_TEST_FIRST_IS_1=true ("1") or
  # --first-is-blank (""). Otherwise probed once with the application loaded:
  # when Rails' test database configuration differs between "" and "1", an
  # existing "...1" database (turbo_tests 2.x provisioning) means "1", a
  # missing one means "" (parallel_tests' convention). Any other error aborts
  # the run instead of guessing.
  module EnvNumber
    MESSAGE = "Cannot determine the TEST_ENV_NUMBER convention (%s: %s). " \
      "Pass --first-is-1 or --first-is-blank (or PARALLEL_TEST_FIRST_IS_1=true)."

    class Ambiguous < StandardError; end

    module_function

    # "1", "" or nil (probe needed).
    def forced(first_is_1, env = ENV)
      return "1" if first_is_1 == true || env["PARALLEL_TEST_FIRST_IS_1"] == "true"
      return "" if first_is_1 == false

      nil
    end

    def detect(options, probe: -> { self.probe })
      first_is_1 = options.respond_to?(:first_is_1) ? options.first_is_1 : options
      value = forced(first_is_1)
      value.nil? ? probe.call : value
    end

    def numbers(first, workers)
      (1..workers).map { |i| i == 1 ? first.to_s : i.to_s }
    end

    def probe(rails: Hooks.rails, active_record: Hooks.active_record, env: ENV)
      return "" unless rails && active_record

      blank = test_config(rails, env, "")
      one = test_config(rails, env, "1")
      return "" if blank.nil? || one.nil? || blank == one

      database_exists?(rails, active_record, one) ? "1" : ""
    end

    def test_config(rails, env, value)
      saved = env.key?("TEST_ENV_NUMBER") ? env["TEST_ENV_NUMBER"] : :unset
      env["TEST_ENV_NUMBER"] = value
      config = rails.application.config.database_configuration
      primary(config && config["test"])
    rescue StandardError => e
      raise Ambiguous, format(MESSAGE, e.class, e.message)
    ensure
      if saved == :unset
        env.delete("TEST_ENV_NUMBER")
      else
        env["TEST_ENV_NUMBER"] = saved
      end
    end

    # Multi-database configurations nest one hash per database.
    def primary(config)
      return nil unless config.is_a?(Hash)
      return config if config.key?("adapter") || config.key?("url") || config.key?("database")

      config["primary"] || config.values.detect { |value| value.is_a?(Hash) }
    end

    def database_exists?(rails, active_record, config)
      adapter = config["adapter"].to_s
      if adapter.include?("sqlite")
        database = config["database"].to_s
        return false if database.empty? || database.include?(":memory:")

        root = rails.respond_to?(:root) && rails.root ? rails.root.to_s : Dir.pwd
        return File.exist?(File.expand_path(database, root))
      end

      klass = probe_class(active_record::Base)
      begin
        klass.establish_connection(config)
        klass.connection.execute("SELECT 1")
        true
      rescue StandardError => e
        return false if no_database_error?(active_record, e)

        raise Ambiguous, format(MESSAGE, e.class, e.message)
      ensure
        begin
          klass.remove_connection if klass.respond_to?(:remove_connection)
        rescue StandardError
          nil
        end
      end
    end

    def no_database_error?(active_record, error)
      active_record.const_defined?(:NoDatabaseError) && error.is_a?(active_record.const_get(:NoDatabaseError))
    end

    # A named abstract class gets its own connection pool, so probing never
    # touches ActiveRecord::Base's connection.
    def probe_class(base)
      if const_defined?(:ProbeRecord, false)
        return const_get(:ProbeRecord, false) if const_get(:ProbeRecord, false).superclass.equal?(base)

        remove_const(:ProbeRecord)
      end
      klass = Class.new(base)
      const_set(:ProbeRecord, klass)
      klass.abstract_class = true if klass.respond_to?(:abstract_class=)
      klass
    end
  end
end
