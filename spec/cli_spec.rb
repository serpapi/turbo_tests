RSpec.describe TurboTests::CLI do
  before { output }

  subject(:output) { `bundle exec turbo_tests -f d #{fixture}`.strip }

  context "when the 'seed' parameter was used" do
    let(:seed) { 1234 }

    subject(:output) { `bundle exec turbo_tests -f d #{fixture} --seed #{seed}`.strip }

    context "errors outside of examples" do
      let(:expected_start_of_output) {
%(
1 processes for 1 specs, ~ 1 specs per process

Randomized with seed #{seed}

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

      let(:expected_end_of_output) do
        "0 examples, 0 failures, 1 error occurred outside of examples\n"\
        "\n"\
        "Randomized with seed #{seed}"
      end

      let(:fixture) { "./fixtures/rspec/errors_outside_of_examples_spec.rb" }

      it "reports" do
        expect($?.exitstatus).to eql(1)

        expect(output).to start_with(expected_start_of_output)
        expect(output).to end_with(expected_end_of_output)
      end
    end

    context "pending exceptions", :aggregate_failures do
      let(:fixture) { "./fixtures/rspec/pending_exceptions_spec.rb" }

      it "reports" do
        expect($?.exitstatus).to eql(0)

        [
          "is implemented but skipped with 'pending' (PENDING: TODO: skipped with 'pending')",
          "is implemented but skipped with 'skip' (PENDING: TODO: skipped with 'skip')",
          "is implemented but skipped with 'xit' (PENDING: Temporarily skipped with xit)",

          "Pending: (Failures listed here are expected and do not affect your suite's status)",
        ].each do |part|
          expect(output).to include(part)
        end

        expect(output).to end_with("3 examples, 0 failures, 3 pending\n\nRandomized with seed #{seed}")
      end
    end
  end

  context "when 'seed' parameter was not used" do
    context "errors outside of examples" do
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

      let(:expected_end_of_output) do
        "0 examples, 0 failures, 1 error occurred outside of examples"
      end

      let(:fixture) { "./fixtures/rspec/errors_outside_of_examples_spec.rb" }

      it "reports" do
        expect($?.exitstatus).to eql(1)

        expect(output).to start_with(expected_start_of_output)
        expect(output).to end_with(expected_end_of_output)
      end

      it "exludes the seed message from the output" do
        expect(output).to_not include("seed")
      end
    end

    context "pending exceptions", :aggregate_failures do
      let(:fixture) { "./fixtures/rspec/pending_exceptions_spec.rb" }

      it "reports" do
        expect($?.exitstatus).to eql(0)

        [
          "is implemented but skipped with 'pending' (PENDING: TODO: skipped with 'pending')",
          "is implemented but skipped with 'skip' (PENDING: TODO: skipped with 'skip')",
          "is implemented but skipped with 'xit' (PENDING: Temporarily skipped with xit)",

          "Pending: (Failures listed here are expected and do not affect your suite's status)",
        ].each do |part|
          expect(output).to include(part)
        end

        expect(output).to end_with("3 examples, 0 failures, 3 pending")
      end
    end
  end

  describe "extra_failure_lines" do
    let(:fixture) { "./fixtures/rspec/failing_spec.rb" }

    it "outputs extra_failure_lines" do
      expect($?.exitstatus).to eql(1)

      expect(output).to include("Test info in extra_failure_lines")
    end
  end

  describe "full error failure message and line" do
    let(:fixture) { "./fixtures/rspec/no_method_error_spec.rb" }

    it "outputs file name and line number" do
      expect($?.exitstatus).to eql(1)

      [
        "undefined method `[]' for nil",
        'it("fails") { expect(nil[:key]).to eql("value") }',
        "# #{fixture}:2:in `block (2 levels) in <top (required)>'",
        "1 example, 1 failure",
      ].each do |part|
        expect(output).to include(part)
      end
    end
  end
end
