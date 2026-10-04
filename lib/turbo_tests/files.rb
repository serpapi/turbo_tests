# frozen_string_literal: true

require "rspec/core"

module TurboTests
  # Spec file discovery with RSpec's own rules (default_path, pattern,
  # exclude_pattern, .rspec/.rspec-local/SPEC_OPTS/--options), evaluated on a
  # private RSpec::Core::Configuration so nothing (spec_helper included) is
  # ever required in the parent process.
  module Files
    LOCATION = /\A(.*?)((?::\d+)+)\z/.freeze
    IDS = /\A(.*?)\[([\d\s:,]+)\]\z/.freeze

    module_function

    # Returns one entry per spec file: an Array with the arguments selecting
    # that file (["spec/a_spec.rb"], or ["spec/a_spec.rb:12:34"] when the user
    # gave line selectors), in RSpec's discovery order.
    def resolve(options)
      rspec_options = rspec_options(options.rspec_args)
      config = RSpec::Core::Configuration.new
      default_path = options.default_path || rspec_options[:default_path] || config.default_path
      pattern = options.pattern || rspec_options[:pattern]
      exclude_pattern = options.exclude_pattern || rspec_options[:exclude_pattern]

      config.default_path = default_path
      config.pattern = pattern if pattern
      config.exclude_pattern = exclude_pattern if exclude_pattern

      inputs = options.files.empty? ? [default_path] : options.files
      selectors = selectors_by_file(inputs)
      config.files_or_directories_to_run = inputs.map { |input| strip_selector(input) }.uniq

      config.files_to_run.uniq.map do |file|
        selectors[file] || [relative(file)]
      end
    end

    def rspec_options(rspec_args)
      RSpec::Core::ConfigurationOptions.new(Array(rspec_args)).options
    end

    # "spec/a_spec.rb:12" / "spec/a_spec.rb[1:2]" => "spec/a_spec.rb"
    def path_of(argument)
      strip_selector(argument.to_s)
    end

    def strip_selector(argument)
      if (match = LOCATION.match(argument))
        match[1]
      elsif (match = IDS.match(argument))
        match[1]
      else
        argument
      end
    end

    def relative(path)
      expanded = File.expand_path(path)
      prefix = Dir.pwd.end_with?(File::SEPARATOR) ? Dir.pwd : "#{Dir.pwd}#{File::SEPARATOR}"
      expanded.start_with?(prefix) ? expanded[prefix.length..-1] : expanded
    end

    def selectors_by_file(inputs)
      locations = Hash.new { |h, k| h[k] = [] }
      ids = Hash.new { |h, k| h[k] = [] }
      inputs.each do |input|
        if (match = LOCATION.match(input))
          locations[File.expand_path(match[1])].concat(match[2].split(":").reject(&:empty?))
        elsif (match = IDS.match(input))
          ids[File.expand_path(match[1])].concat(match[2].split(",").map(&:strip))
        end
      end

      result = {}
      (locations.keys | ids.keys).each do |file|
        entry = []
        entry << "#{relative(file)}:#{locations[file].uniq.join(":")}" unless locations[file].empty?
        entry << "#{relative(file)}[#{ids[file].uniq.join(",")}]" unless ids[file].empty?
        result[file] = entry
      end
      result
    end
  end
end
