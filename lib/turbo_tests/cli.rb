# frozen_string_literal: true

require "optparse"

module TurboTests
  class CLI
    def initialize(argv)
      @argv = argv
    end

    def run
      requires = []
      formatters = []
      tags = []
      count = nil
      verbose = false
      fail_fast = nil

      OptionParser.new { |opts|
        opts.banner = <<~BANNER
          Run all tests in parallel, giving each process ENV['TEST_ENV_NUMBER'] ('1', '2', '3', ...).

          Uses parallel_tests under the hood, but reports test results incrementally. Based on Discourse and RubyGems work in this area.

          Usage: turbo_tests [options]

          [optional] Only selected files & folders:
            turbo_tests spec/bar spec/baz/xxx_spec.rb

          Options:
        BANNER

        opts.on("-n [PROCESSES]", Integer, "How many processes to use, default: available CPUs") { |n| count = n }

        opts.on("-r", "--require PATH", "Require a file.") do |filename|
          requires << filename
        end

        opts.on("-f", "--format FORMATTER", "Choose a formatter. Available formatters: progress (p), documentation (d). Default: progress") do |name|
          formatters << {
            name: name,
            outputs: []
          }
        end

        opts.on("-t", "--tag TAG", "Run examples with the specified tag.") do |tag|
          tags << tag
        end

        opts.on("-o", "--out FILE", "Write output to a file instead of $stdout") do |filename|
          if formatters.empty?
            formatters << {
              name: "progress",
              outputs: []
            }
          end
          formatters.last[:outputs] << filename
        end

        opts.on("-v", "--verbose", "More output") do
          verbose = true
        end

        opts.on("--fail-fast=[N]") do |n|
          n = begin
            Integer(n)
          rescue
            nil
          end
          fail_fast = n.nil? || n < 1 ? 1 : n
        end
      }.parse!(@argv)

      requires.each { |f| require(f) }

      if formatters.empty?
        formatters << {
          name: "progress",
          outputs: []
        }
      end

      formatters.each do |formatter|
        if formatter[:outputs].empty?
          formatter[:outputs] << "-"
        end
      end

      success = TurboTests::Runner.run(
        formatters: formatters,
        tags: tags,
        files: @argv.empty? ? ["spec"] : @argv,
        verbose: verbose,
        fail_fast: fail_fast,
        count: count,
      )

      if success
        exit 0
      else
        exit 1
      end
    end
  end
end
