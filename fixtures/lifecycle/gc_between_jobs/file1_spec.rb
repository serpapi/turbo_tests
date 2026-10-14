require_relative "spec_helper"

RSpec.describe "gc between jobs 1" do
  it("one") { GC.start; expect(1).to eq(1) }
  it("two") { GC.compact if GC.respond_to?(:compact) && RUBY_VERSION >= "3"; expect(1).to eq(1) }
end
