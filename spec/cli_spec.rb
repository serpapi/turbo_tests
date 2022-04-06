RSpec.describe TurboTests::CLI do
  let(:bin) { Pathname(__dir__).join("../bin/turbo_tests").expand_path }

  context "passing spec" do
    let(:fixture) { "./fixtures/rspec/passing_spec.rb" }

    it "works with tags" do
      result = `bundle exec turbo_tests -t unknown-tag -f d #{fixture}`.strip
      expect(result).to include("All examples were filtered out")
      expect(result).to end_with("0 examples, 0 failures")
      expect($?.success?).to be true
    end

    it "returns success" do
      result = `bundle exec turbo_tests -f d #{fixture}`.strip
      expect(result).to end_with("1 example, 0 failures")
      expect($?.success?).to be true
    end

    it "works with extra test_options" do
      extra = "'--failure-exit-code=2'"
      result = `bundle exec turbo_tests --test-options #{extra} -f d #{fixture}`.strip
      expect($?.success?).to be true
      expect(result).to end_with("1 example, 0 failures")
    end

  end

  context "failing spec" do
    let(:fixture) { "./fixtures/rspec/failing_spec.rb" }

    it "works with tags" do
      result = `bundle exec turbo_tests -t unknown-tag -f d #{fixture}`.strip
      expect(result).to include("All examples were filtered out")
      expect(result).to end_with("0 examples, 0 failures")
    end

    it "aborts with a custom failure exit code" do
      extra = "'--failure-exit-code=2'"
      result = `bundle exec turbo_tests --test-options #{extra} -f d #{fixture}`.strip
      expect(result).to include("1 example, 1 failure")
      expect($?.success?).to be false
      expect($?.exitstatus).to eq(2)
    end
  end


  context "errors outside of examples" do
    let(:fixture) { "./fixtures/rspec/errors_outside_of_examples_spec.rb" }

    let(:expected_start_of_output) {
      %(
1 processes for 1 specs, ~ 1 specs per process

An error occurred while loading #{fixture}.
\e[31mFailure/Error: \e[0m\e[1;34m1\e[0m / \e[1;34m0\e[0m\e[0m
\e[31m\e[0m
\e[31mZeroDivisionError:\e[0m
\e[31m  divided by 0\e[0m
\e[36m# #{fixture}:4:in `/'\e[0m
\e[36m# #{fixture}:4:in `block in <top (required)>'\e[0m
\e[36m# #{fixture}:1:in `<top (required)>'\e[0m
).strip
    }

    it "reports" do
      output = `bundle exec turbo_tests -f d #{fixture} 2>&1`.strip
      expect($?.exitstatus).to eql(1)

      expect(output).to start_with(expected_start_of_output)
      expect(output).to end_with("0 examples, 0 failures")
    end
  end

  context "pending exceptions", :aggregate_failures do
    let(:fixture) { "./fixtures/rspec/pending_exceptions_spec.rb" }

    it "reports" do
      output = `bundle exec turbo_tests -f d #{fixture} 2>&1`.strip
      expect($?.exitstatus).to eql(0)

      [
        "is implemented but skipped with 'pending' (PENDING: TODO: skipped with 'pending')",
        "is implemented but skipped with 'skip' (PENDING: TODO: skipped with 'skip')",
        "is implemented but skipped with 'xit' (PENDING: Temporarily skipped with xit)",

        "Pending: (Failures listed here are expected and do not affect your suite's status)",

        %{
Fixture of spec file with pending failed examples is implemented but skipped with 'pending'
    # TODO: skipped with 'pending'
    Failure/Error: DEFAULT_FAILURE_NOTIFIER = lambda { |failure, _opts| raise failure }

      expected: 3
            got: 2

      (compared using ==)
        }.strip,

        %(
Fixture of spec file with pending failed examples is implemented but skipped with 'skip'
    # TODO: skipped with 'skip'
        ).strip,

        %(
Fixture of spec file with pending failed examples is implemented but skipped with 'xit'
    # Temporarily skipped with xit
        ).strip
      ].each do |part|
        expect(output).to include(part)
      end

      expect(output).to end_with("3 examples, 0 failures, 3 pending")
    end
  end
end
