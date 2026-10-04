RSpec.describe TurboTests do
  it "has a version number" do
    expect(TurboTests::VERSION).not_to be nil
  end

  it "depends on rspec-core only" do
    expect($LOADED_FEATURES.grep(%r{/parallel_tests/})).to eq([])
  end
end
