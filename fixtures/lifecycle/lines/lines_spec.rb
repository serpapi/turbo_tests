RSpec.describe "line selectors" do
  it("first") { expect(1).to eq(1) }

  it("second must not run") { raise "not selected" }

  it("third") { expect(3).to eq(3) }
end
