RSpec.describe "Fixture of spec file with pending failed examples" do
  it "is implemented but skipped with 'pending'" do
    pending("TODO: skipped with 'pending'")

    expect(2).to eq(3)
  end

  it "is implemented but skipped with 'skip'", skip: "TODO: skipped with 'skip'" do
    expect(100).to eq(500)
  end

  xit "is implemented but skipped with 'xit'" do
    expect(1).to eq(42)
  end
end
