RSpec.describe "Fixture of spec file with errors outside of examples" do
  it("passes") { expect(2 * 2).to eql(4) }

  1 / 0
end
