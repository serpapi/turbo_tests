RSpec.shared_examples "a shared behaviour" do
  it "fails inside shared examples" do
    expect(1).to eq(2)
  end
end

RSpec.describe "JUnit fixture" do
  it("passes") { expect(1).to eq(1) }

  it("fails with a cause") do
    begin
      raise ArgumentError, "inner problem"
    rescue ArgumentError
      raise "outer problem"
    end
  end

  it("is pending") do
    pending("not implemented yet")
    expect(1).to eq(2)
  end

  it("is skipped", skip: "later") { expect(1).to eq(1) }

  it("records extra failure lines") do |example|
    example.metadata[:extra_failure_lines] = ["first extra line", "second extra line"]
    expect(2).to eq(3)
  end

  context "nested context" do
    it("fails an expectation") { expect([1, 2]).to eq([1, 3]) }

    it_behaves_like "a shared behaviour"
  end
end
