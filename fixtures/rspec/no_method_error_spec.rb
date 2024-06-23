RSpec.describe "NoMethodError spec" do
  it("fails") { expect(nil[:key]).to eql("value") }
end