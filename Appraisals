# frozen_string_literal: true

appraise "ruby-2-7" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
end

appraise "ruby-3-0" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
end

appraise "ruby-3-1" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
end

appraise "ruby-3-2" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
end

appraise "ruby-3-3" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
end

appraise "ruby-3-4" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
end

# Only run security audit on latest Ruby version
appraise "audit" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
  eval_gemfile "modular/audit.gemfile"
end

# Only run coverage on latest Ruby version
appraise "coverage" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
  eval_gemfile "modular/coverage.gemfile"
end

# Only run linter on latest Ruby version (but, in support of oldest supported Ruby version)
appraise "style" do
  gem "mutex_m", "~> 0.2"
  gem "stringio", "~> 3.0"
  eval_gemfile "modular/style.gemfile"
end

appraise "ruby-head" do
  gem "mutex_m", ">= 0.2"
  gem "stringio", ">= 3.0"
end

appraise "truffleruby-head" do
  gem "mutex_m", ">= 0.2"
  gem "stringio", ">= 3.0"
end

appraise "jruby-head" do
  gem "mutex_m", ">= 0.2"
  gem "stringio", ">= 3.0"
end
