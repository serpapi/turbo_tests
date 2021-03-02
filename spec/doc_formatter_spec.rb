sleep 3

RSpec.describe "Top-level context" do
  describe "#instance_method" do
    it "does what it's supposed to" do
      expect(true).to be_truthy
    end

    it "doesn't do what it isn't supposed to" do
      expect(false).not_to be_truthy
    end
  end
end