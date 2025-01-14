RSpec.describe("Failing example group") do
  after do |example|
    example.metadata[:extra_failure_lines] ||= []

    lines = example.metadata[:extra_failure_lines]

    lines << "Test info in extra_failure_lines"
  end

  it "fails" do
    expect(2).to(eq(3))
  end
end
