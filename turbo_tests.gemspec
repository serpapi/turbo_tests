require_relative "lib/turbo_tests/version"

Gem::Specification.new do |spec|
  spec.name = "turbo_tests"
  spec.version = TurboTests::VERSION
  spec.platform = Gem::Platform::RUBY
  spec.date = Time.now.strftime('%Y-%m-%d')

  spec.summary = "`turbo_tests` is a drop-in replacement for `grosser/parallel_tests` with incremental summarized output. Source code of `turbo_test` gem is based on Discourse and Rubygems work in this area (see README file of the source repository)."
  spec.homepage = "https://github.com/serpapi/turbo_tests"
  spec.license = "MIT"

  spec.authors = ["Illia Zub"]
  spec.email = ["ilya@serpapi.com"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/serpapi/turbo_tests"
  spec.metadata["changelog_uri"] = "https://github.com/serpapi/turbo_tests/releases"

  spec.required_ruby_version = ">= 2.7"

  spec.add_dependency "rspec", ">= 3.10"
  spec.add_dependency "parallel_tests", ">= 3.3.0", "< 5"

  spec.add_development_dependency "pry", "~> 0.14"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path("..", __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end

  spec.executables = ["turbo_tests"]
end
