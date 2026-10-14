require "tmpdir"

RSpec.describe TurboTests::RuntimeLog do
  around do |example|
    begin
      root = File.expand_path("../../tmp", __dir__)
      FileUtils.mkdir_p(root)
      dir = Dir.mktmpdir("runtime_log", root)
      original = Dir.pwd
      Dir.chdir(dir)
      example.run
    ensure
      Dir.chdir(original)
      FileUtils.rm_rf(dir)
    end
  end

  it "parses parallel_tests' format and normalizes paths" do
    times = described_class.parse(<<~LOG)
      spec/a_spec.rb:1.5
      ./spec/b_spec.rb:0.25
      spec/c_spec.rb:4.0e-05
      garbage line
      spec/d_spec.rb:-1
    LOG

    expect(times).to eq("spec/a_spec.rb" => 1.5, "spec/b_spec.rb" => 0.25, "spec/c_spec.rb" => 4.0e-05)
  end

  it "loads the first existing candidate" do
    FileUtils.mkdir_p("tmp")
    File.write("tmp/parallel_runtime_rspec.log", "spec/a_spec.rb:2\n")

    expect(described_class.load_first(described_class.candidates(TurboTests::Options.new)))
      .to eq(["tmp/parallel_runtime_rspec.log", {"spec/a_spec.rb" => 2.0}])

    File.write("tmp/turbo_rspec_runtime.log", "spec/a_spec.rb:3\n")
    expect(described_class.load(described_class.candidates(TurboTests::Options.new))).to eq("spec/a_spec.rb" => 3.0)
    expect(described_class.load(["missing.log"])).to eq({})
  end

  it "uses --runtime-log exclusively when given" do
    FileUtils.mkdir_p("tmp")
    File.write("tmp/turbo_rspec_runtime.log", "spec/a_spec.rb:3\n")
    options = TurboTests::Options.new(runtime_log: "custom.log")

    expect(described_class.candidates(options)).to eq(["custom.log"])
    expect(described_class.save_path(options)).to eq("custom.log")
  end

  it "saves sorted relative paths, merging with entries of files that still exist" do
    FileUtils.mkdir_p("spec")
    %w[a b c].each { |name| File.write("spec/#{name}_spec.rb", "") }
    FileUtils.mkdir_p("tmp")
    File.write("tmp/log", "spec/c_spec.rb:9\nspec/deleted_spec.rb:1\nspec/a_spec.rb:7\n")

    expect(described_class.save("tmp/log", "spec/b_spec.rb" => 0.5, File.expand_path("spec/a_spec.rb") => 1.25)).to be(true)

    expect(File.read("tmp/log")).to eq("spec/a_spec.rb:1.25\nspec/b_spec.rb:0.5\nspec/c_spec.rb:9.0\n")
  end

  it "creates missing directories" do
    File.write("a_spec.rb", "")

    described_class.save("deep/dir/runtime.log", "a_spec.rb" => 1)

    expect(File.read("deep/dir/runtime.log")).to eq("a_spec.rb:1.0\n")
  end

  it "warns instead of raising when the log cannot be written" do
    File.write("blocker", "")

    expect {
      expect(described_class.save("blocker/runtime.log", "a_spec.rb" => 1)).to be(false)
    }.to output(/could not write runtime log/).to_stderr
  end
end
