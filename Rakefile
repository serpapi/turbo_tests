# frozen_string_literal: true

require "bundler/gem_tasks"

begin
  require "rspec/core/rake_task"

  RSpec::Core::RakeTask.new(:spec)
rescue LoadError
  task(:spec) do
    warn("RSpec is disabled")
  end
end

desc "alias test task to spec"
task test: :spec

begin
  require "reek/rake/task"
  Reek::Rake::Task.new do |t|
    t.fail_on_error = true
    t.verbose = false
    t.source_files = "{spec,spec_ignored,spec_orms,lib}/**/*.rb"
  end
rescue LoadError
  task(:reek) do
    warn("reek is disabled")
  end
end

begin
  require "yard-junk/rake"

  YardJunk::Rake.define_task
rescue LoadError
  task("yard:junk") do
    warn("yard:junk is disabled")
  end
end

begin
  require "yard"

  YARD::Rake::YardocTask.new(:yard)
rescue LoadError
  task(:yard) do
    warn("yard is disabled")
  end
end

begin
  require "rubocop/lts"
  Rubocop::Lts.install_tasks
rescue LoadError
  task(:rubocop_gradual) do
    warn("RuboCop (Gradual) is disabled")
  end
end

# These tests do not require any services to be running, so this is what we run as default
task default: %i[spec rubocop_gradual:autocorrect yard yard:junk]
