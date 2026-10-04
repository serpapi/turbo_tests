RSpec.describe "Fuubar fixture" do
  3.times do |index|
    it("passes #{index}") { expect(index).to be >= 0 }
  end

  it("fails") { expect(1).to eq(2) }

  it("is skipped", skip: "later") { expect(1).to eq(1) }
end
