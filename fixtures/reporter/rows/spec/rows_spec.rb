# Prints bytes that are not valid UTF-8, here and in an exception message,
# to prove rows stay valid JSON.
RSpec.describe "Rows fixture" do
  it("passes") { expect(1).to eq(1) }

  it("fails with a cause") do
    begin
      raise ArgumentError, "inner problem"
    rescue ArgumentError
      raise "outer problem"
    end
  end

  it("fails with binary bytes in the message") do
    raise "bad bytes: \xFF\xFE".b
  end

  it("records extra failure lines") do |example|
    example.metadata[:extra_failure_lines] = ["extra line \xFF".b, "second line"]
    expect(2).to eq(3)
  end

  it("is pending") do
    pending("not implemented yet")
    expect(1).to eq(2)
  end

  it("is skipped", skip: "later") { expect(1).to eq(1) }

  it("sends a message with binary bytes") do
    RSpec.configuration.reporter.message("message bytes: \xFF".b)
  end

  context "nested context" do
    it_behaves_like "a shared behaviour"
  end
end
