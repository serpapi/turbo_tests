require_relative "spec_helper"

RSpec.describe "filters 1" do
  it("runs") { expect(1).to eq(1) }
  it("is excluded", :slow) { raise "excluded example ran in file 1" }
end
