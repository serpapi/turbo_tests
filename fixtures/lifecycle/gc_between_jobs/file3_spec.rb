require_relative "spec_helper"

RSpec.describe "gc between jobs 3" do
  it("one") { GC.start; expect(3).to eq(3) }
  it("two") { GC.compact if GC.respond_to?(:compact) && RUBY_VERSION >= "3"; expect(3).to eq(3) }
end
