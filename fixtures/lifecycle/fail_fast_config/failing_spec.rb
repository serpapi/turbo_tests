require_relative "spec_helper"

RSpec.describe "fail fast" do
  after(:context) { sleep 0.5 }

  it("fails") { expect(1).to eq(2) }
  it("never runs") { expect(1).to eq(1) }
end
