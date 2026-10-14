# frozen_string_literal: true

module TurboTests
  # Decides which files a worker runs next.
  #
  # dynamic (default): one job per file, heaviest first, so the slowest files
  # start early and the tail is made of short jobs. Files whose recorded
  # runtime is below chunk_seconds are packed together into ~chunk_seconds
  # jobs to save per-job overhead.
  #
  # static: greedy LPT (longest processing time first) split into `groups`
  # groups, the 2.x shape: each group is one job for its own worker. With
  # only_group the selected groups' files are dispatched dynamically.
  class Scheduler
    Job = Struct.new(:id, :files, :weight, :group)

    DEFAULT_WEIGHT = 1.0

    attr_reader :mode, :groups_count, :weights

    def initialize(files, runtimes, workers:, mode: :dynamic, groups: nil, only_group: [], chunk_seconds: 1.0, group_by: :runtime)
      @entries = files.map { |entry| Array(entry) }
      @runtimes = runtimes || {}
      @workers = [workers.to_i, 1].max
      @mode = mode
      @groups_count = [(groups || @workers).to_i, 1].max
      @only_group = Array(only_group)
      @chunk_seconds = chunk_seconds.to_f
      @group_by = group_by || :runtime
      @next_id = 0
      @outstanding = {}
      @durations = {}
      @weights = compute_weights
      @chunk_target = chunk_target
      @queue = build_queue
    end

    # The files this run covers (after --only-group selection).
    def files
      @queue.flat_map(&:files) + @outstanding.values.flat_map(&:files)
    end

    def entries_count
      @selected_entries_count
    end

    # [[files of group 1], [files of group 2], ...]
    def static_groups
      group_indexes.map { |group| group.flat_map { |i| @entries[i] } }
    end

    # Dynamic mode hands out the head of the queue. Static mode (without
    # --only-group) is the 2.x shape: worker i runs group i (and i+workers,
    # ... when there are more groups than workers), nothing else.
    def next_job(worker_id = nil)
      return nil if @queue.empty?

      index = 0
      if @mode == :static && @only_group.empty? && worker_id
        index = @queue.index { |job| (job.group - 1) % @workers == worker_id - 1 }
        return nil unless index
      end
      job = @queue.delete_at(index)
      @outstanding[job.id] = job
      job
    end

    def report(job, duration)
      @outstanding.delete(job.id)
      @durations[job.id] = duration
    end

    def cancel
      @queue.clear
    end

    def pending?
      !@queue.empty?
    end

    def done?
      @queue.empty? && @outstanding.empty?
    end

    def size
      @queue.size
    end

    private

    def compute_weights
      paths = @entries.map { |entry| Files.path_of(entry.first) }
      case @group_by
      when :filesize
        paths.map do |path|
          begin
            File.size(path).to_f
          rescue SystemCallError
            0.0
          end
        end
      when :found
        paths.map { DEFAULT_WEIGHT }
      else
        known = paths.map { |path| @runtimes[path] }
        values = known.compact
        fallback = values.empty? ? DEFAULT_WEIGHT : values.inject(0.0) { |sum, v| sum + v } / values.size
        @known_runtime = known.map { |v| !v.nil? }
        known.map { |v| v.nil? ? fallback : v.to_f }
      end
    end

    def build_queue
      if @mode == :static
        groups = group_indexes
        if @only_group.empty?
          jobs = []
          groups.each_with_index do |group, index|
            next if group.empty?

            jobs << new_job(group.flat_map { |i| @entries[i] }, group.inject(0.0) { |s, i| s + @weights[i] }, index + 1)
          end
          @selected_entries_count = @entries.size
          return jobs
        end

        selected = @only_group.flat_map { |g| groups[g - 1] || [] }
        @selected_entries_count = selected.size
        return dynamic_jobs(selected)
      end

      @selected_entries_count = @entries.size
      dynamic_jobs((0...@entries.size).to_a)
    end

    def dynamic_jobs(indexes)
      ordered = @group_by == :found ? indexes : sort_by_weight(indexes)
      jobs = []
      chunk = []
      chunk_weight = 0.0
      ordered.each do |i|
        if chunkable?(i)
          chunk << i
          chunk_weight += @weights[i]
          if chunk_weight >= @chunk_target
            jobs << new_job(chunk.flat_map { |c| @entries[c] }, chunk_weight)
            chunk = []
            chunk_weight = 0.0
          end
        else
          unless chunk.empty?
            jobs << new_job(chunk.flat_map { |c| @entries[c] }, chunk_weight)
            chunk = []
            chunk_weight = 0.0
          end
          jobs << new_job(@entries[i], @weights[i])
        end
      end
      jobs << new_job(chunk.flat_map { |c| @entries[c] }, chunk_weight) unless chunk.empty?
      jobs
    end

    def chunkable?(index)
      @group_by == :runtime && @chunk_seconds > 0 && @known_runtime && @known_runtime[index] &&
        @weights[index] < @chunk_target
    end

    # Packed jobs stay small enough to leave about four jobs per worker, so
    # a suite of tiny files still spreads over every worker.
    def chunk_target
      total = @weights.inject(0.0) { |sum, weight| sum + weight }
      [@chunk_seconds, total / (@workers * 4)].min
    end

    # Descending by weight; equal weights keep discovery order.
    def sort_by_weight(indexes)
      indexes.sort_by { |i| [-@weights[i], i] }
    end

    def group_indexes
      @group_indexes ||= lpt_groups(@entries, @groups_count)
    end

    def lpt_groups(entries, count)
      groups = Array.new(count) { [] }
      return groups if entries.empty?

      indexes = (0...entries.size).to_a
      if @group_by == :found
        indexes.each_with_index { |i, position| groups[position % count] << i }
        return groups
      end

      totals = Array.new(count, 0.0)
      sort_by_weight(indexes).each do |i|
        target = (0...count).min_by { |g| [totals[g], g] }
        groups[target] << i
        totals[target] += @weights[i]
      end
      groups
    end

    def new_job(files, weight, group = nil)
      @next_id += 1
      Job.new(@next_id, files, weight, group)
    end
  end
end
