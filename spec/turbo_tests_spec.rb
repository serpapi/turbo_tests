RSpec.describe TurboTests do
  it "has a version number" do
    expect(TurboTests::VERSION).not_to be nil
  end

  describe "create" do
    context "with nil count" do
      it "creates databases" do
        expect(ParallelTests::Tasks)
          .to receive(:run_in_parallel)
          .with(["bundle", "exec", "rake", "db:create", "RAILS_ENV=test"], {:count=>""})

        TurboTests::Runner.create(nil)
      end
    end

    context "with count" do
      it "creates databases" do
        expect(ParallelTests::Tasks)
          .to receive(:run_in_parallel)
          .with(["bundle", "exec", "rake", "db:create", "RAILS_ENV=test"], {:count=>"4"})

        TurboTests::Runner.create(4)
      end
    end
  end
end
