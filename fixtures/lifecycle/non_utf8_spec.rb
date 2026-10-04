# encoding: utf-8
RSpec.describe "non-UTF-8 output" do
  it "prints raw bytes and accents (é)" do
    $stdout.write("raw bytes: \xFF\xFE\n".b)
    $stdout.write("accent: é\n")
    expect(1).to eq(1)
  end
end
