# frozen_string_literal: true

require "json"

module TurboTests
  # Wire format between workers and the parent: one JSON object per line.
  #
  # Two transports exist:
  # * dedicated: the worker was given a file descriptor just for rows
  #   (TURBO_TESTS_ROWS_FD); every line on it is a row.
  # * mixed: rows share the worker's stdout with regular output; each row line
  #   is prefixed with a per-run marker (RSPEC_FORMATTER_OUTPUT_ID) so the
  #   parent can tell rows from passthrough output.
  module Protocol
    ROWS_FD_ENV = "TURBO_TESTS_ROWS_FD"
    PREFIX_ENV = "RSPEC_FORMATTER_OUTPUT_ID"

    class Writer
      def initialize(io, prefix = nil)
        @io = io
        @prefix = prefix
      end

      def write(row)
        line = JSON.generate(row)
        @io.write(@prefix ? "#{@prefix}#{line}\n" : "#{line}\n")
        @io.flush
      end
    end

    # Turns lines read from a worker into rows (Hash with symbol keys) or
    # passthrough output (String), according to the transport in use.
    class Reader
      def initialize(prefix = nil)
        @prefix = prefix && prefix.b
      end

      # Returns an Array of [:output, String] / [:row, Hash] pairs (1 or 2
      # items: in mixed mode a row may share its line with output printed
      # just before it).
      def parse_line(line)
        line = line.b
        unless @prefix
          row = decode(line)
          return row ? [[:row, row]] : [[:output, line]]
        end

        marker = line.index(@prefix)
        return [[:output, line]] unless marker

        row = decode(line[(marker + @prefix.length)..-1])
        return [[:output, line]] unless row

        items = []
        items << [:output, line[0...marker]] if marker > 0
        items << [:row, row]
        items
      end

      private

      def decode(text)
        text = text.dup.force_encoding(Encoding::UTF_8)
        text = text.scrub unless text.valid_encoding?
        row = JSON.parse(text, symbolize_names: true)
        row.is_a?(Hash) && row.key?(:type) ? row : nil
      rescue JSON::ParserError
        nil
      end
    end

    # Writer for the current process, resolved from the environment.
    def self.default_writer(fallback_output)
      fd = ENV[ROWS_FD_ENV]
      if fd && !fd.empty?
        Writer.new(IO.for_fd(Integer(fd), "w"))
      else
        Writer.new(fallback_output, ENV[PREFIX_ENV])
      end
    end
  end
end
