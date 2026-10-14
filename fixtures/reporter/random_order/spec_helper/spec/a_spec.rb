RSpec.describe "Group a" do
  10.times do |index|
    it("example a#{index}") { expect(index).to be >= 0 }
  end
end
