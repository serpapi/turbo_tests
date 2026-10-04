RSpec.configure do |config|
  config.disable_monkey_patching!
end

RSpec.shared_examples "a shared behaviour" do
  it "fails inside shared examples" do
    expect(1).to eq(2)
  end
end
