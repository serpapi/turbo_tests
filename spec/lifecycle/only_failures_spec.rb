require_relative "lifecycle_helper"

RSpec.describe "--only-failures (fixtures/lifecycle/only_failures)" do
  let(:project) { File.join(LifecycleHelper::ROOT, LifecycleHelper::FIXTURES, "only_failures") }
  let(:status_file) { File.join(File.dirname(fixture_log), "status.txt") }

  %w[fork spawn].each do |pool|
    context "with --pool #{pool}" do
      it "runs only the files with recorded failures, using the persistence file from spec_helper" do
        env = {"TURBO_TESTS_FIXTURE_STATUS" => status_file}
        first = turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log", chdir: project, env: env)
        expect(first.exitstatus).to eq(1), first.to_s
        expect(plain(first.stdout)).to include("3 examples, 1 failure")

        second = turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log", "--only-failures", chdir: project, env: env)
        expect(second.exitstatus).to eq(1), second.to_s
        expect(plain(second.stdout)).to include("for 1 spec file", "1 example, 1 failure")

        fixed = turbo_tests("--pool", pool, "-n", "2", "--no-runtime-log", "--only-failures", chdir: project,
          env: env.merge("TURBO_TESTS_FIXTURE_FIXED" => "1"))
        expect(fixed.exitstatus).to eq(0), fixed.to_s
        expect(plain(fixed.stdout)).to include("1 example, 0 failures")
      end
    end
  end
end
