RSpec.describe TurboTests::Protocol do
  describe TurboTests::Protocol::Writer do
    it "writes one JSON object per line, prefixed in mixed mode" do
      io = StringIO.new
      described_class.new(io).write(type: "ready", worker: 1)
      described_class.new(io, "PFX").write(type: "exit")

      expect(io.string).to eq(%({"type":"ready","worker":1}\nPFX{"type":"exit"}\n))
    end
  end

  describe TurboTests::Protocol::Reader do
    it "parses every line of a dedicated channel as a row" do
      reader = described_class.new

      expect(reader.parse_line(%({"type":"close"}\n))).to eq([[:row, {type: "close"}]])
      expect { reader.parse_line("not json\n") }.to raise_error(TurboTests::Protocol::Error)
    end

    it "separates rows from output in mixed mode" do
      reader = described_class.new("PFX")

      expect(reader.parse_line("plain output\n")).to eq([[:output, "plain output\n"]])
      expect(reader.parse_line(%(dots..PFX{"type":"seed","seed":1}\n)))
        .to eq([[:output, "dots.."], [:row, {type: "seed", seed: 1}]])
      expect(reader.parse_line("PFX not json\n")).to eq([[:output, "PFX not json\n"]])
      expect(reader.parse_line(%(PFX{"no_type":1}\n))).to eq([[:output, %(PFX{"no_type":1}\n)]])
    end

    it "is binary safe and scrubs invalid UTF-8 inside rows" do
      reader = described_class.new("PFX")
      line = "\xFF raw\n".b

      expect(reader.parse_line(line)).to eq([[:output, line]])
      kind, row = reader.parse_line(%(PFX{"type":"message","message":"\xFF\xC3\xA9"}\n).b).first
      expect(kind).to eq(:row)
      expect(row[:message]).to eq("\uFFFDé")
      expect(row[:message]).to be_valid_encoding
    end
  end

  describe TurboTests::Protocol::LineBuffer do
    it "yields complete lines and keeps the partial tail" do
      buffer = described_class.new
      lines = []

      buffer << "one\ntw"
      buffer.each_line { |line| lines << line }
      buffer << "o\nthree"
      buffer.each_line { |line| lines << line }

      expect(lines).to eq(["one\n", "two\n"])
      expect(buffer.flush).to eq("three")
      expect(buffer).to be_empty
    end

    it "handles bytes that are not valid in any encoding" do
      buffer = described_class.new
      buffer << "\xFF\xFE\n".b << "é\n"
      lines = []
      buffer.each_line { |line| lines << line }

      expect(lines).to eq(["\xFF\xFE\n".b, "é\n".b])
    end
  end

  it "decodes rows and rejects non-rows" do
    expect(described_class.decode(%({"type":"job","id":1,"files":["a"]}))).to eq(type: "job", id: 1, files: ["a"])
    expect(described_class.decode("[1]")).to be_nil
    expect(described_class.decode("{")).to be_nil
    expect(described_class.encode(type: "shutdown")).to eq(%({"type":"shutdown"}\n))
  end

  describe ".default_writer" do
    # Also runs inside turbo_tests workers: keep their rows IO untouched.
    around do |example|
      begin
        saved = ENV.to_h.slice(described_class::ROWS_FD_ENV, described_class::PREFIX_ENV)
        saved_io = described_class.instance_variable_get(:@rows_io)
        described_class.instance_variable_set(:@rows_io, nil)
        example.run
      ensure
        described_class.instance_variable_set(:@rows_io, saved_io)
        ENV.delete(described_class::ROWS_FD_ENV)
        ENV.delete(described_class::PREFIX_ENV)
        ENV.update(saved)
      end
    end

    it "shares one rows IO for the whole process, surviving GC" do
      begin
        reader, writer = IO.pipe
        ENV[described_class::ROWS_FD_ENV] = writer.fileno.to_s

        first = described_class.default_writer($stdout)
        GC.start
        second = described_class.default_writer($stdout)
        second.write(type: "ready")

        expect(first.io).to equal(second.io)
        expect(second.io.close_on_exec?).to be(true)
        expect(reader.gets).to eq(%({"type":"ready"}\n))
      ensure
        described_class.instance_variable_set(:@rows_io, nil)
        reader&.close
        writer&.close
      end
    end

    it "lets a forked child drop the inherited IO" do
      fd = IO.sysopen(File::NULL, "w")
      ENV[described_class::ROWS_FD_ENV] = fd.to_s
      io = described_class.default_writer($stdout).io

      described_class.reset_rows_io

      expect(io).to be_closed
      expect(described_class.instance_variable_get(:@rows_io)).to be_nil
    end

    it "writes prefixed rows to the fallback output in mixed mode" do
      ENV.delete(described_class::ROWS_FD_ENV)
      ENV[described_class::PREFIX_ENV] = "ID"
      io = StringIO.new

      described_class.default_writer(io).write(type: "close")

      expect(io.string).to eq(%(ID{"type":"close"}\n))
    end
  end
end
