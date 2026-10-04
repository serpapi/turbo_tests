require "tmpdir"

RSpec.describe TurboTests::Files do
  def options(**attributes)
    TurboTests::Options.new(attributes)
  end

  around do |example|
    root = File.expand_path("../../tmp", __dir__)
    FileUtils.mkdir_p(root)
    dir = Dir.mktmpdir("files", root)
    original = Dir.pwd
    Dir.chdir(dir)
    saved_spec_opts = ENV.delete("SPEC_OPTS")
    example.run
  ensure
    if saved_spec_opts
      ENV["SPEC_OPTS"] = saved_spec_opts
    else
      ENV.delete("SPEC_OPTS")
    end
    Dir.chdir(original)
    FileUtils.rm_rf(dir)
  end

  def touch(*paths)
    paths.each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "RSpec.describe('x') { it('y') {} }\n")
    end
  end

  it "discovers spec files under the default path in rspec order" do
    touch("spec/b_spec.rb", "spec/a_spec.rb", "spec/models/c_spec.rb", "spec/support/helper.rb")

    expect(described_class.resolve(options)).to eq([["spec/a_spec.rb"], ["spec/b_spec.rb"], ["spec/models/c_spec.rb"]])
  end

  it "honours --default-path, --pattern and --exclude-pattern" do
    touch("test/a_test.rb", "test/b_test.rb", "test/slow/c_test.rb", "spec/x_spec.rb")

    resolved = described_class.resolve(options(default_path: "test", pattern: "**/*_test.rb", exclude_pattern: "**/slow/**"))

    expect(resolved).to eq([["test/a_test.rb"], ["test/b_test.rb"]])
  end

  it "keeps path:line and id selectors per file" do
    touch("spec/a_spec.rb", "spec/b_spec.rb", "spec/c_spec.rb")

    resolved = described_class.resolve(options(files: ["spec/a_spec.rb:3", "./spec/a_spec.rb:7:9", "spec/b_spec.rb[1:2]", "spec/c_spec.rb"]))

    expect(resolved).to eq([["spec/a_spec.rb:3:7:9"], ["spec/b_spec.rb[1:2]"], ["spec/c_spec.rb"]])
  end

  it "reads pattern and default path from .rspec without requiring spec_helper" do
    touch("checks/one_check.rb", "checks/two_check.rb", "spec/a_spec.rb")
    File.write("spec/spec_helper.rb", "raise 'spec_helper must not be required in the parent'\n")
    File.write(".rspec", "--require spec_helper\n--default-path checks\n--pattern **/*_check.rb\n")

    expect(described_class.resolve(options)).to eq([["checks/one_check.rb"], ["checks/two_check.rb"]])
  end

  it "lets explicit options win over .rspec and honours SPEC_OPTS" do
    touch("spec/a_spec.rb", "spec/b_check.rb")
    File.write(".rspec", "--pattern **/*_check.rb\n")
    ENV["SPEC_OPTS"] = "--exclude-pattern **/b_*"

    expect(described_class.resolve(options)).to eq([])
    expect(described_class.resolve(options(pattern: "**/*_spec.rb"))).to eq([["spec/a_spec.rb"]])
  end

  it "reads options from rspec args (e.g. --options .rspec_parallel)" do
    touch("spec/a_spec.rb", "spec/b_check.rb")
    File.write(".rspec_parallel", "--pattern **/*_check.rb\n")

    expect(described_class.resolve(options(rspec_args: ["--options", ".rspec_parallel"]))).to eq([["spec/b_check.rb"]])
  end

  it "returns nothing when the default path does not exist" do
    expect(described_class.resolve(options)).to eq([])
  end

  it "keeps explicitly given files even if they do not exist (rspec reports the load error)" do
    expect(described_class.resolve(options(files: ["spec/missing_spec.rb"]))).to eq([["spec/missing_spec.rb"]])
  end

  it "strips selectors" do
    expect(described_class.path_of("spec/a_spec.rb:12:30")).to eq("spec/a_spec.rb")
    expect(described_class.path_of("spec/a_spec.rb[1:2,1:3]")).to eq("spec/a_spec.rb")
    expect(described_class.path_of("spec/a_spec.rb")).to eq("spec/a_spec.rb")
  end
end
