RSpec.describe "Group b" do
  10.times do |index|
    it("example b#{index}") { expect(index).to be >= 0 }
  end
end
