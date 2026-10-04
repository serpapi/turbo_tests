RSpec.describe TurboTests::Scheduler do
  def entries(*paths)
    paths.map { |path| [path] }
  end

  def drain(scheduler, worker_id = nil)
    jobs = []
    while (job = scheduler.next_job(worker_id))
      jobs << job
      scheduler.report(job, job.weight)
    end
    jobs
  end

  describe "dynamic mode" do
    it "hands out the heaviest files first and keeps discovery order for ties" do
      files = entries("a", "b", "c", "d")
      scheduler = described_class.new(files, {"a" => 1.0, "b" => 5.0, "c" => 3.0, "d" => 3.0}, workers: 2, chunk_seconds: 0)

      expect(drain(scheduler).map(&:files)).to eq([["b"], ["c"], ["d"], ["a"]])
      expect(scheduler).to be_done
    end

    it "assumes the average known runtime for unknown files" do
      files = entries("known_small", "unknown", "known_big")
      scheduler = described_class.new(files, {"known_small" => 2.0, "known_big" => 10.0}, workers: 2, chunk_seconds: 0)

      expect(scheduler.weights).to eq([2.0, 6.0, 10.0])
      expect(drain(scheduler).map(&:files)).to eq([["known_big"], ["unknown"], ["known_small"]])
    end

    it "uses 1 second per file when nothing is known, one file per job" do
      scheduler = described_class.new(entries("a", "b", "c"), {}, workers: 2)

      expect(scheduler.weights).to eq([1.0, 1.0, 1.0])
      expect(drain(scheduler).map(&:files)).to eq([["a"], ["b"], ["c"]])
    end

    it "chunks consecutive tiny files with known runtimes into ~chunk_seconds jobs" do
      runtimes = {"big" => 5.0, "t1" => 0.4, "t2" => 0.4, "t3" => 0.3, "t4" => 0.2, "t5" => 0.1}
      scheduler = described_class.new(entries("t1", "big", "t2", "t3", "t4", "t5", "new"), runtimes, workers: 2, chunk_seconds: 1.0)

      jobs = drain(scheduler)

      expect(jobs.map(&:files)).to eq([["big"], ["new"], ["t1", "t2", "t3"], ["t4", "t5"]])
      expect(jobs.map(&:id)).to eq([1, 2, 3, 4])
    end

    it "keeps packed jobs small enough to use every worker" do
      runtimes = (1..40).map { |i| ["f#{i}", 0.01] }.to_h
      scheduler = described_class.new(entries(*runtimes.keys), runtimes, workers: 4, chunk_seconds: 1.0)

      jobs = drain(scheduler)

      # 0.4s in total over 4 workers: ~0.025s jobs of 3 files, not one 1s job.
      expect(jobs.size).to be >= 13
      expect(jobs.flat_map(&:files).sort).to eq(runtimes.keys.sort)
    end

    it "preserves line selectors inside jobs" do
      scheduler = described_class.new([["a_spec.rb:12:30"], ["b_spec.rb"]], {"a_spec.rb" => 3.0, "b_spec.rb" => 1.0}, workers: 1, chunk_seconds: 0)

      expect(drain(scheduler).map(&:files)).to eq([["a_spec.rb:12:30"], ["b_spec.rb"]])
    end

    it "tracks outstanding jobs until reported" do
      scheduler = described_class.new(entries("a"), {}, workers: 1)
      job = scheduler.next_job

      expect(scheduler.next_job).to be_nil
      expect(scheduler).not_to be_done
      scheduler.report(job, 0.1)
      expect(scheduler).to be_done
    end

    it "can be cancelled" do
      scheduler = described_class.new(entries("a", "b"), {}, workers: 1)
      scheduler.cancel

      expect(scheduler.next_job).to be_nil
      expect(scheduler).to be_done
    end

    it "orders by file size with --group-by filesize" do
      sizes = {"s" => 10, "l" => 1000, "m" => 100}
      allow(File).to receive(:size) { |path| sizes.fetch(path) }
      scheduler = described_class.new(entries("s", "l", "m"), {"s" => 99.0}, workers: 2, group_by: :filesize)

      expect(drain(scheduler).map(&:files)).to eq([["l"], ["m"], ["s"]])
    end

    it "keeps discovery order with --group-by found" do
      scheduler = described_class.new(entries("c", "a", "b"), {"a" => 9.0}, workers: 2, group_by: :found)

      expect(drain(scheduler).map(&:files)).to eq([["c"], ["a"], ["b"]])
    end
  end

  describe "static mode (LPT)" do
    let(:runtimes) { {"a" => 7.0, "b" => 6.0, "c" => 5.0, "d" => 4.0, "e" => 3.0, "f" => 2.0, "g" => 2.0} }
    let(:files) { entries("g", "f", "e", "d", "c", "b", "a") }

    it "assigns each file, heaviest first, to the least loaded group" do
      scheduler = described_class.new(files, runtimes, workers: 3, mode: :static)

      # a7 b6 c5 | d4 -> c (5) | e3 -> b (6) | g2 -> a (7) | f2 -> a (tie, lowest index) => totals 11, 9, 9
      expect(scheduler.static_groups).to eq([["a", "g", "f"], ["b", "e"], ["c", "d"]])
    end

    it "makes one job per group, run by its own worker" do
      scheduler = described_class.new(files, runtimes, workers: 3, mode: :static)

      expect(scheduler.next_job(2).files).to eq(["b", "e"])
      expect(scheduler.next_job(1).files).to eq(["a", "g", "f"])
      expect(scheduler.next_job(2)).to be_nil
      expect(scheduler.next_job(3).files).to eq(["c", "d"])
      expect(scheduler.next_job(3)).to be_nil
    end

    it "deals extra groups round-robin when there are more groups than workers" do
      scheduler = described_class.new(entries("a", "b", "c", "d"), {}, workers: 2, mode: :static, groups: 4)

      expect([scheduler.next_job(2), scheduler.next_job(2), scheduler.next_job(2)].map { |job| job&.group }).to eq([2, 4, nil])
      expect([scheduler.next_job(1), scheduler.next_job(1)].map(&:group)).to eq([1, 3])
    end

    it "with --only-group runs the selected groups' files dynamically" do
      scheduler = described_class.new(files, runtimes, workers: 8, mode: :static, groups: 3, only_group: [1, 3], chunk_seconds: 0)

      expect(scheduler.entries_count).to eq(5)
      expect(drain(scheduler).map(&:files)).to eq([["a"], ["c"], ["d"], ["g"], ["f"]])
    end

    it "splits round-robin in discovery order with --group-by found" do
      scheduler = described_class.new(files, runtimes, workers: 3, mode: :static, group_by: :found)

      expect(scheduler.static_groups).to eq([["g", "d", "a"], ["f", "c"], ["e", "b"]])
    end

    it "leaves groups empty when there are fewer files than groups" do
      scheduler = described_class.new(entries("a"), {}, workers: 3, mode: :static)

      expect(scheduler.static_groups).to eq([["a"], [], []])
      expect(drain(scheduler, 1).map(&:files)).to eq([["a"]])
    end
  end
end
