# frozen_string_literal: true

require "json"

module TurboTests
  # Wire format between processes: one JSON object per line.
  #
  # Two transports exist for worker rows:
  # * dedicated: the worker was given a file descriptor just for rows
  #   (TURBO_TESTS_ROWS_FD); every line on it is a row.
  # * mixed: rows share the worker's stdout with regular output; each row line
  #   is prefixed with a per-run marker (RSPEC_FORMATTER_OUTPUT_ID) so the
  #   parent can tell rows from passthrough output.
  #
  # Jobs (parent -> worker stdin) and control rows (preloader -> parent) are
  # plain JSON lines.
  module Protocol
    ROWS_FD_ENV = "TURBO_TESTS_ROWS_FD"
    PREFIX_ENV = "RSPEC_FORMATTER_OUTPUT_ID"

    @rows_io = nil

    class Error < StandardError; end

    class Writer
      attr_reader :io

      def initialize(io, prefix = nil)
        @io = io
        @prefix = prefix
      end

      def write(row)
        @io.write(line(row))
        @io.flush
      end

      def write_all(rows)
        @io.write(rows.map { |row| line(row) }.join)
        @io.flush
      end

      private

      def line(row)
        json = JSON.generate(row)
        @prefix ? "#{@prefix}#{json}\n" : "#{json}\n"
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
      # just before it). On a dedicated channel every line must be a row.
      def parse_line(line)
        line = line.b
        unless @prefix
          row = Protocol.decode(line)
          raise Error, "malformed row on dedicated channel: #{line.inspect[0, 200]}" unless row

          return [[:row, row]]
        end

        marker = line.index(@prefix)
        return [[:output, line]] unless marker

        row = Protocol.decode(line[(marker + @prefix.length)..-1])
        return [[:output, line]] unless row

        items = []
        items << [:output, line[0...marker]] if marker > 0
        items << [:row, row]
        items
      end
    end

    # Splits a byte stream into lines without assuming any encoding.
    class LineBuffer
      def initialize
        @buffer = "".b
      end

      def <<(chunk)
        @buffer << chunk.b
        self
      end

      # Yields every complete line (including its "\n").
      def each_line
        start = 0
        while (newline = @buffer.index("\n", start))
          yield @buffer.byteslice(start, newline + 1 - start)
          start = newline + 1
        end
        @buffer = @buffer.byteslice(start, @buffer.bytesize - start) if start > 0
      end

      # The incomplete tail, consumed.
      def flush
        rest = @buffer
        @buffer = "".b
        rest
      end

      def empty?
        @buffer.empty?
      end
    end

    # A Hash with symbol keys and a :type, or nil.
    def self.decode(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub unless text.valid_encoding?
      row = JSON.parse(text, symbolize_names: true)
      row.is_a?(Hash) && row.key?(:type) ? row : nil
    rescue JSON::ParserError
      nil
    end

    def self.encode(row)
      "#{JSON.generate(row)}\n"
    end

    # Writer for the current process, resolved from the environment. The
    # dedicated rows IO lives as long as the process: formatters are
    # re-created per job and must all share one IO object (a fresh
    # IO.for_fd per job would close the fd when garbage collected).
    def self.default_writer(fallback_output)
      fd = ENV[ROWS_FD_ENV]
      if fd && !fd.empty?
        Writer.new(rows_io(Integer(fd)))
      else
        Writer.new(fallback_output, ENV[PREFIX_ENV])
      end
    end

    # Forked children drop the IO inherited from their parent (closing that
    # descriptor) before resolving their own.
    # Forked workers drop the preloader's control pipe: closing really closes
    # the descriptor here, unlike the non-owning wrapper's normal lifetime.
    def self.reset_rows_io
      io = @rows_io
      @rows_io = nil
      return unless io && !io.closed?

      io.autoclose = true
      io.close
    rescue IOError, SystemCallError
      nil
    end

    # The wrapper never owns the descriptor (autoclose: false): the fd lives as
    # long as the worker, and a garbage-collected owning wrapper would close
    # whatever pipe had been given the same number in the meantime.
    def self.rows_io(fd)
      @rows_io = nil if @rows_io && (@rows_io.closed? || @rows_io.fileno != fd)
      @rows_io ||= begin
        io = IO.for_fd(fd, "w", autoclose: false)
        io.sync = true
        begin
          io.close_on_exec = true
        rescue NotImplementedError
          nil
        end
        io
      end
    end
  end
end
