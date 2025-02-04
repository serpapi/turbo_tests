source "https://rubygems.org"

#### IMPORTANT #######################################################
# Gemfile is for local development ONLY; Gemfile is NOT loaded in CI #
####################################################### IMPORTANT ####

# Specify your gem's general development dependencies in turbo_tests.gemspec
gemspec

# Security Audit
if RUBY_VERSION >= "3"
  # NOTE: Audit fails on Ruby 2.7 because nokogiri has dropped support for Ruby < 3
  # See: https://github.com/sparklemotion/nokogiri/security/advisories/GHSA-r95h-9x8f-r3f7
  # We can't add upgraded nokogiri here unless we are developing on Ruby 3+
  eval_gemfile "gemfiles/modular/audit.gemfile"
end

# Code Coverage
eval_gemfile "gemfiles/modular/coverage.gemfile"

# Linting
eval_gemfile "gemfiles/modular/style.gemfile"

# Documentation
eval_gemfile "gemfiles/modular/documentation.gemfile"

gem "appraisal", path: "/Users/pboling/src/forks/appraisal"
