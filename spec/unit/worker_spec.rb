# frozen_string_literal: true

RSpec.describe TurboTests::Worker do
  describe "#prune_shared_example_groups" do
    # Keeps the real suite's world untouched by working on a private World.
    let(:world) { RSpec::Core::World.new(RSpec::Core::Configuration.new) }
    let(:registry) { world.shared_example_group_registry }
    let(:group_class) { Class.new(RSpec::Core::ExampleGroup) }

    it "drops groups registered under example group classes and keeps top-level ones" do
      registry.add(group_class, "nested") { }
      registry.add(:main, "top level") { }

      described_class.new({}).__send__(:prune_shared_example_groups, world)

      expect(registry.find([group_class], "nested")).to be_nil
      expect(registry.find([], "top level")).not_to be_nil
    end
  end
end
