require_relative "spec_helper"

RSpec.describe "gc between jobs 2" do
  it("one") { GC.start; expect(2).to eq(2) }
  it("two") { GC.compact if GC.respond_to?(:compact) && RUBY_VERSION >= "3"; expect(2).to eq(2) }
end
