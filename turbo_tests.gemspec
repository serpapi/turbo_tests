require_relative "lib/turbo_tests/version"

Gem::Specification.new do |spec|
  spec.name = "turbo_tests"
  spec.version = TurboTests::VERSION
  spec.platform = Gem::Platform::RUBY
  spec.date = Time.now.strftime('%Y-%m-%d')

  spec.summary = "Run an RSpec suite across worker processes and read it as one rspec run."
  spec.description = "Preloads the suite once, forks workers that take spec files from a queue ordered by recorded " \
                     "runtime, and replays their results as a single incremental rspec stream. Accepts rspec, " \
                     "parallel_rspec and flatware arguments; workers that finish RSpec but never exit fail the run " \
                     "instead of hanging it. Depends on rspec-core only."
  spec.homepage = "https://github.com/serpapi/turbo_tests"
  spec.license = "MIT"

  spec.authors = ["Illia Zub"]
  spec.email = ["ilya@serpapi.com"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/serpapi/turbo_tests"
  spec.metadata["changelog_uri"] = "https://github.com/serpapi/turbo_tests/blob/master/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/serpapi/turbo_tests/issues"

  spec.required_ruby_version = ">= 2.4"

  spec.add_dependency "rspec-core", ">= 3.10"

  spec.add_development_dependency "pry", "~> 0.14"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path("..", __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features|fixtures|assets)/|^\.github/}) }
  end

  spec.executables = ["turbo_tests"]
end
