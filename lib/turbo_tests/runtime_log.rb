# frozen_string_literal: true

require "fileutils"

module TurboTests
  # Per-file runtimes in parallel_tests' format: one "path:seconds" per line.
  module RuntimeLog
    DEFAULT_PATH = "tmp/turbo_rspec_runtime.log"
    PARALLEL_TESTS_PATH = "tmp/parallel_runtime_rspec.log"
    LINE = /\A(.+):(\d+(?:\.\d+)?(?:e-?\d+)?)\s*\z/i.freeze

    module_function

    def candidates(options)
      options.runtime_log ? [options.runtime_log] : [DEFAULT_PATH, PARALLEL_TESTS_PATH]
    end

    def save_path(options)
      options.runtime_log || DEFAULT_PATH
    end

    # Returns [path, {relative_path => seconds}] for the first existing
    # candidate, or [nil, {}].
    def load_first(paths)
      Array(paths).each do |path|
        next unless File.file?(path)

        return [path, parse(File.read(path))]
      end
      [nil, {}]
    rescue SystemCallError, IOError => e
      warn "turbo_tests: could not read runtime log: #{e.message}"
      [nil, {}]
    end

    def load(paths)
      load_first(paths).last
    end

    def parse(text)
      times = {}
      text.each_line do |line|
        line = line.dup.force_encoding(Encoding::UTF_8)
        next unless line.valid_encoding?

        match = LINE.match(line.strip)
        next unless match

        seconds = Float(match[2])
        next if seconds.nan? || seconds < 0

        times[normalize(match[1])] = seconds
      end
      times
    end

    def normalize(path)
      path = path.sub(/\A\.\//, "")
      expanded = File.expand_path(path)
      prefix = "#{Dir.pwd}#{File::SEPARATOR}"
      expanded.start_with?(prefix) ? expanded[prefix.length..-1] : path
    end

    # Merges the measured times into what the file already holds (so a
    # partial run, e.g. --only-group, keeps the other files' entries), drops
    # entries for files that no longer exist and writes atomically.
    def save(path, times)
      existing = File.file?(path) ? parse(File.read(path)) : {}
      merged = existing.merge(stringify(times))
      merged.delete_if { |file, _| !File.exist?(file) }

      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, "w") do |io|
        merged.keys.sort.each { |file| io.puts("#{file}:#{format_seconds(merged[file])}") }
      end
      File.rename(tmp, path)
      true
    rescue SystemCallError, IOError => e
      begin
        File.unlink(tmp) if tmp && File.exist?(tmp)
      rescue SystemCallError
        nil
      end
      warn "turbo_tests: could not write runtime log #{path}: #{e.message}"
      false
    end

    def stringify(times)
      result = {}
      times.each { |file, seconds| result[normalize(file.to_s)] = seconds.to_f }
      result
    end

    def format_seconds(seconds)
      format("%.6f", seconds.to_f).sub(/0+\z/, "").sub(/\.\z/, ".0")
    end
  end
end
