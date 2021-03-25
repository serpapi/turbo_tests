RSpec.describe TurboTests::CLI do
  let(:expected_start_of_output) {
%(1 processes for 1 specs, ~ 1 specs per process

An error occurred while loading ./fixtures/rspec/errors_outside_of_examples_spec.rb.
\e[31mFailure/Error: \e[0m\e[1;34m1\e[0m / \e[1;34m0\e[0m\e[0m
\e[31m\e[0m
\e[31mZeroDivisionError:\e[0m
\e[31m  divided by 0\e[0m
\e[36m# ./fixtures/rspec/errors_outside_of_examples_spec.rb:4:in `/'\e[0m
\e[36m# ./fixtures/rspec/errors_outside_of_examples_spec.rb:4:in `block in <top (required)>'\e[0m
\e[36m# ./fixtures/rspec/errors_outside_of_examples_spec.rb:1:in `<top (required)>'\e[0m).strip
  }

  it "reports errors outside of examples" do
    output = `bundle exec turbo_tests ./fixtures/rspec/errors_outside_of_examples_spec.rb`.strip

    expect($?.exitstatus).to eql(1)

    expect(output).to start_with(expected_start_of_output)
    expect(output).to end_with("0 examples, 0 failures")
  end
end
