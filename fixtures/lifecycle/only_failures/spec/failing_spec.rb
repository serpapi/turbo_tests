RSpec.describe "failing file" do
  it("passes too") { expect(1).to eq(1) }
  it("fails unless told otherwise") { expect(ENV["TURBO_TESTS_FIXTURE_FIXED"]).to eq("1") }
end
