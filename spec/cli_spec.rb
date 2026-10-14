RSpec.describe TurboTests::CLI do
  before { output }

  subject(:output) { `bundle exec turbo_tests -f d #{fixture}`.strip }

  # Ruby 3.4 quotes 'method' and prefixes the owner (Integer#/); older
  # Rubies print `method'.
  def frame(fixture, line, label)
    /\e\[36m# #{Regexp.escape(fixture)}:#{line}:in [`'](?:\w+#)?#{Regexp.escape(label)}'\e\[0m/
  end

  def banner
    /\A1 worker \((?:fork|spawn|command)\) for 1 spec file\n/
  end

  def error_outside_of_examples(fixture)
    Regexp.new(
      "An error occurred while loading #{Regexp.escape(fixture)}\\.\n" \
      "#{Regexp.escape("\e[31mFailure/Error: \e[0m\e[1;34m1\e[0m / \e[1;34m0\e[0m\e[0m")}\n" \
      "#{Regexp.escape("\e[31m\e[0m")}\n" \
      "#{Regexp.escape("\e[31mZeroDivisionError:\e[0m")}\n" \
      "#{Regexp.escape("\e[31m  divided by 0\e[0m")}\n" \
      "#{frame(fixture, 4, "/").source}\n" \
      "#{frame(fixture, 4, "block in <top (required)>").source}\n" \
      "#{frame(fixture, 1, "<top (required)>").source}"
    )
  end

  context "when the 'seed' parameter was used" do
    let(:seed) { 1234 }

    subject(:output) { `bundle exec turbo_tests -f d #{fixture} --seed #{seed}`.strip }

    context "errors outside of examples" do
      # rspec reports a seed only when it ordered something; a run that stops
      # at load time ends with the summary, as a serial `rspec --seed` does.
      let(:expected_end_of_output) { "0 examples, 0 failures, 1 error occurred outside of examples" }

      let(:fixture) { "./fixtures/rspec/errors_outside_of_examples_spec.rb" }

      it "reports" do
        expect($?.exitstatus).to eql(1)

        expect(output).to match(/#{banner.source}\nRandomized with seed #{seed}\n\n#{error_outside_of_examples(fixture).source}/)
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
      let(:expected_end_of_output) do
        "0 examples, 0 failures, 1 error occurred outside of examples"
      end

      let(:fixture) { "./fixtures/rspec/errors_outside_of_examples_spec.rb" }

      it "reports" do
        expect($?.exitstatus).to eql(1)

        expect(output).to match(/#{banner.source}\n#{error_outside_of_examples(fixture).source}/)
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

      expect(output).to match(/undefined method [`']\[\]' for nil/)
      expect(output).to include('it("fails") { expect(nil[:key]).to eql("value") }')
      expect(output).to match(/# #{Regexp.escape(fixture)}:2:in [`']block \(2 levels\) in <top \(required\)>'/)
      expect(output).to include("1 example, 1 failure")
    end
  end

  describe "invalid options" do
    subject(:output) { `bundle exec turbo_tests --frobnicate 2>&1`.strip }

    it "exits 1 with a usage hint" do
      expect($?.exitstatus).to eql(1)
      expect(output).to include("turbo_tests: invalid option: --frobnicate", "turbo_tests --help")
    end
  end
end
