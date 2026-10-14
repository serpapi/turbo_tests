source "https://rubygems.org"

# Specify your gem's dependencies in turbo_tests.gemspec
gemspec

gem "rake", "~> 13.0"

# The suite uses rspec-expectations and rspec-mocks; the gem itself only needs rspec-core.
gem "rspec", ">= 3.10"

# bin/check_ruby24_syntax parses lib/ and bin/ with the Ruby 2.4 grammar.
gem "parser", require: false

# Custom formatters exercised by spec/reporter/integration_spec.rb.
gem "fuubar", require: false
gem "rspec_junit_formatter", require: false
