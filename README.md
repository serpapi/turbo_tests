<h1 align="center">
  TurboTests
</h1>

<div align="center">
   <img src="https://user-images.githubusercontent.com/78694043/233910064-87a6d557-1120-42d2-b965-2a9403c6f2f4.svg" width="500" alt="Turbo-Tests">

</div>

<div align="center">

  ![Tests](https://github.com/serpapi/turbo_tests/workflows/Tests/badge.svg)

</div>

`turbo_tests` is a drop-in replacement for [`grosser/parallel_tests`](https://github.com/grosser/parallel_tests) with incremental summarized output. Source code of this gem is based on [Discourse](https://github.com/discourse/discourse/blob/6b9784cf8a18636bce281a7e4d18e65a0cbc6290/lib/turbo_tests.rb) and [RubyGems](https://github.com/rubygems/rubygems/tree/390335ceb351668cd433bd5bb9823dd021f82533/bundler/tool) work in this area.

Incremental summarized output [doesn't fit vision of `parallel_tests` author](https://github.com/grosser/parallel_tests/issues/708) and [RSpec doesn't support built-in parallel testing yet](https://github.com/rspec/rspec-rails/issues/2104#issuecomment-658474900). This gem will not be useful once one of the issues above will be implemented.

## Why incremental output?

`parallel_tests` is great, but it messes output:

```bash

$ bundle exec rake parallel_tests:spec[^spec/search]
.................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................

Finished in 1 minute 6.92 seconds (files took 6.95 seconds to load)
2616 examples, 0 failures

.........................................................................................................................................F........................................................................................................................................F..............................................................................................................................................................................................................................................................................................

Finished in 1 minute 35.05 seconds (files took 6.26 seconds to load)
2158 examples, 2 failures

.................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................

Finished in 1 minute 35.05 seconds (files took 6.26 seconds to load)
2158 examples, 0 failures
```

`turbo_tests` output looks like regular `rspec`:

```bash
$ bundle exec turbo_tests
..........................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................F........................................................................................................................................F..............................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................

Finished in 2 minute 25.15 seconds (files took 0 seconds to load)
6873 examples, 2 failures
```

## Install

Add the gem:

```ruby
gem 'turbo_tests'
```

Then install:

```bash
bundle install
```

Requirements:

| Item | Requirement |
|---|---|
| Ruby | `>= 2.4` |
| Runtime dependency | `rspec-core >= 3.10` |
| Not required | `parallel_tests` |

## Usage

Run the suite:

```bash
bundle exec turbo_tests
```

Set workers:

```bash
bundle exec turbo_tests -n 8
```

Select files and directories:

```bash
bundle exec turbo_tests spec/models spec/services/user_spec.rb
```

Select a line:

```bash
bundle exec turbo_tests spec/services/user_spec.rb:42
```

Pass options to RSpec after `--`:

```bash
bundle exec turbo_tests -n 4 -- --example "creates a user"
```

Pass RSpec options and then more files after a second `--`:

```bash
bundle exec turbo_tests -- --format documentation -- spec/models/user_spec.rb
```

v3 option set:

```text
Run RSpec in parallel workers, giving each ENV['TEST_ENV_NUMBER'] ('', '2', '3', ...).

Reports test results incrementally. Source code of `turbo_tests` gem is based on Discourse and RubyGems work in this area (see README file of the source repository).

Usage: turbo_tests [options] [files or directories] [-- rspec options [-- files]]

[optional] Only selected files & folders:
  turbo_tests spec/bar spec/baz/xxx_spec.rb

Options:
    -n, -w, --workers N             How many workers to use, default: PARALLEL_TEST_PROCESSORS or available CPUs
    -r, --require PATH              Require a file in the parent process (e.g. a custom formatter).
    -f, --format FORMATTER          Choose a formatter. Available formatters: progress (p), documentation (d). Default: progress
    -o, --out FILE                  Write output to a file instead of $stdout
    -t, --tag TAG                   Run examples with the specified tag.
        --seed SEED                 Seed for rspec (forces random order, as in rspec)
        --order TYPE                Forwarded to rspec: defined, rand[:SEED], random[:SEED], recently-modified
        --fail-fast=[N]             Stop dispatching and interrupt workers after N failures (default 1)
        --pattern PATTERN           Load files matching pattern (rspec --pattern)
        --exclude-pattern PATTERN   Skip files matching pattern (rspec --exclude-pattern)
        --default-path PATH         Directory used when no files are given (rspec --default-path)
        --group-by TYPE             Weights for scheduling: runtime (default), filesize, found
        --only-group LIST           Split files into static groups and run only these (1-based, e.g. 2,3)
        --groups N                  Number of static groups (default: number of workers)
        --runtime-log FILE          Location of previously recorded test runtimes
        --no-runtime-log            Do not record runtimes after the run
        --record-runtime            Record runtimes after the run (default)
        --first-is-1                First worker gets TEST_ENV_NUMBER=1 (default: auto-detect)
        --first-is-blank            First worker gets TEST_ENV_NUMBER='' (default: auto-detect)
        --nice                      Run workers with lower CPU priority
        --preload FILE              File the fork preloader requires before forking (default: .rspec --require files)
        --pool TYPE                 Worker pool: auto (default), fork, spawn, command
        --static                    Split files into one static group per worker (2.x scheduling)
        --exit-timeout SECONDS      Kill workers that do not exit SECONDS after finishing (default 60, 0 = wait forever)
        --diagnose                  Collect extra diagnostics (perf/bpftrace when available) for hung workers
        --print-failed-group        Print a command that reruns the files of failed jobs
        --profile=[N]               Show the N slowest examples and groups (default 10)
        --only-failures             Run only examples that failed last time (rspec --only-failures)
        --next-failure              rspec --next-failure: --only-failures --fail-fast --order defined
    -v, --verbose                   More output
        --test-options OPTIONS      Extra rspec options as one string (parallel_rspec compatible)
        --no-rake-hooks             Do not run turbo_tests:setup / turbo_tests:cleanup rake tasks
        --version                   Print version
    -h, --help                      Show this help
```

## Swap in

### From plain `rspec`

Replace the executable:

```bash
bundle exec rspec spec/models/user_spec.rb:42
bundle exec turbo_tests spec/models/user_spec.rb:42
```

RSpec discovery is used. `.rspec`, `.rspec-local`, `SPEC_OPTS`, `--default-path`, `--pattern`, and `--exclude-pattern` are honoured. `spec_helper` is not loaded in the parent while discovering files.

### From `parallel_tests` / `parallel_rspec`

Keep the common flags:

```bash
bundle exec parallel_rspec -n 8 --pattern "spec/**/*_spec.rb" --exclude-pattern "spec/system/**/*_spec.rb"
bundle exec turbo_tests -n 8 --pattern "spec/**/*_spec.rb" --exclude-pattern "spec/system/**/*_spec.rb"
```

Compatibility map:

| `parallel_tests` input | `turbo_tests` behaviour |
|---|---|
| `-n N` | worker count |
| `--pattern`, `--exclude-pattern` | RSpec file discovery |
| `--group-by runtime|filesize|found` | scheduler weight |
| `--only-group 2`, `--groups 8` | static group selection for CI shards |
| `--test-options "..."` | split as RSpec options |
| `.rspec_parallel`, `spec/parallel_spec.opts`, `spec/spec.opts` | read when no explicit `--options` is passed after `--` |
| `PARALLEL_TEST_PROCESSORS` | default worker count |
| `PARALLEL_TEST_FIRST_IS_1=true` | first worker gets `TEST_ENV_NUMBER=1` |
| `tmp/parallel_runtime_rspec.log` | read when present |
| `tmp/turbo_rspec_runtime.log` | default runtime log written by `turbo_tests` |

Create Rails databases with the same rake task:

```bash
PARALLEL_TEST_FIRST_IS_1=true bundle exec rake parallel:create
bundle exec turbo_tests --first-is-1
```

or the blank-first convention:

```bash
bundle exec rake parallel:create
bundle exec turbo_tests --first-is-blank
```

`TEST_ENV_NUMBER` is auto-detected for Rails + ActiveRecord when possible. The banner prints the chosen values.

### From `flatware`

A leading `rspec` token is ignored, so the RSpec form ports directly:

```bash
bundle exec flatware rspec -w 8 spec -- --tag focus
bundle exec turbo_tests rspec -w 8 spec -- --tag focus
```

Hook mapping:

```ruby
# .turbo_tests.rb
TurboTests.configure do |config|
  config.before_fork { ActiveRecord::Base.connection_handler.clear_all_connections! }
  config.after_fork { |worker| ActiveRecord::Base.establish_connection(:test) }
end
```

Differences:

| Area | Difference |
|---|---|
| Documentation formatter | output is replayed by the parent formatter from JSON rows |
| Windows | uses spawn or command pools, not fork |
| DRb socket file | none; transport is JSON rows over pipes |

## How it works

```text
parent CLI
  -> file discovery
  -> scheduler: dynamic per-file queue, largest runtime first
  -> pool: fork preloader on MRI Unix, spawn elsewhere, command for v2-style rspec commands
  -> workers emit JSON rows over pipes
  -> supervisor tracks booting/ready/busy/shutdown/exited
  -> reporter replays one RSpec-looking stream
```

Runtime logs are always read when present and recorded after runs unless `--no-runtime-log` is set. The log format is `path:seconds` and is compatible with `parallel_tests`.

`config.example_status_persistence_file_path` (the file behind `--only-failures`) is written once per run, by the parent, with rspec's own merge: examples that were loaded but did not run keep their previous status. rspec rewrites the whole file under an exclusive lock at the end of a process; writing it from every worker after every file would be quadratic in the number of recorded examples and would serialise the workers on that lock (on a suite with 130k examples one such write took 1.1 s). `--pool command` workers are plain `rspec` processes and write it themselves, once each.

Shutdown is bounded. After RSpec finishes, a worker that will not exit gets a `SIGUSR1` thread dump, diagnostics, `TERM`, then `KILL`; the run exits nonzero.

Exit status is `0` only when examples pass and no worker hangs, crashes, or reports an error outside examples. Otherwise it is the maximum RSpec worker status or `1`. A run stopped by Ctrl-C exits `130` (a second Ctrl-C kills the workers immediately), one stopped by `SIGTERM` exits `143`. `--pool command` runs one `rspec` process per static group, so it needs `--groups` ≤ `-n` (the default).

`bin/benchmark` on a 16-core arm64 laptop, 4 workers, median wall time of 5 runs (`fixtures/benchmark`, generated; `--json FILE` keeps the raw samples, and the CI perf job is configured to upload them as `perf-artifacts`):

| suite | serial `rspec` | turbo_tests 2.2.5 | v3 fork | v3 spawn | v3 command |
|---|---|---|---|---|---|
| `uneven_8` (8 files, sleeps 4/0.2/3/0.2/2/0.2/1/0.2 s) | 11.06 s | 4.53 s | 4.39 s | 4.35 s | 4.53 s |
| `uneven_64` (64 files, log-normal sleeps) | 27.33 s | 7.27 s | 7.77 s (7.15 s with `--static`) | 7.60 s (7.17 s with `--static`) | 7.31 s |
| `slow_boot` (spec_helper sleeps 2 s, 8 files) | 2.26 s | 2.45 s | 2.39 s | 2.36 s | 2.42 s |
| mean CPU user+sys on `uneven_64` | 0.22 s | 1.11 s | 0.57 s (0.44 s with `--static`) | 0.96 s | 1.01 s |
| largest process RSS on `uneven_64` | 34.9 MB | 39.2 MB | 26.4 MB | 26.5 MB | 28.1 MB |

Sleep-bound suites sit at the 4-worker bound in every configuration; the fork pool's gain on this hardware is CPU
(one boot instead of N) and per-process memory, not wall time. The RSS column is what `time -l` reports: the largest
resident set of any process in the run, parent or worker. Dynamic dispatch costs a few milliseconds per job, which
shows on 64 one-example files: all five dynamic fork runs (7.46–8.39 s) were slower than all five 2.2.5 runs
(7.24–7.30 s), while `--static` runs (7.11–7.17 s) were faster. It pays off when file runtimes are uneven and not yet
recorded. Other work shared the machine during the measurement; single-run outliers up to +2.3 s were kept in the
medians. Running this repository's own suite through `bin/turbo_tests -n 8`
takes 17 s against 118 s serial. `bin/leak_check` (300 files through one worker, Ruby 3.4.8): RSS +0.6 % (fork) and
+0.3 % (spawn) over the last third of the run, live objects flat after a full GC.

## Hooks

Create `.turbo_tests.rb` in the project root:

```ruby
TurboTests.configure do |config|
  config.before_fork do
    ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord::Base)
  end

  config.after_fork do |worker_number|
    ActiveRecord::Base.establish_connection(:test) if defined?(ActiveRecord::Base)
  end
end
```

Defaults cover common Rails + ActiveRecord and SimpleCov fork cases. In the fork pool, SimpleCov uses `SimpleCov.at_fork.call(worker_number)` when available. macOS gets `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` for the preloader unless already set.

Use escape hatches when a suite is not fork-safe:

```bash
bundle exec turbo_tests --pool spawn
bundle exec turbo_tests --pool command --static
```

For `pg` in forked workers, try:

```bash
PGGSSENCMODE=disable bundle exec turbo_tests
```

Thread pools, connection pools, and clients opened before fork are inherited. Close them in `before_fork` and reconnect in `after_fork`.

## Databases and TEST_ENV_NUMBER

Worker 1 is chosen once per run:

| Input | Worker 1 |
|---|---|
| `--first-is-1` | `1` |
| `PARALLEL_TEST_FIRST_IS_1=true` | `1` |
| `--first-is-blank` | blank |
| Rails + ActiveRecord auto-detect finds the `1` database | `1` |
| Rails + ActiveRecord auto-detect finds only the blank database | blank |
| no Rails + ActiveRecord probe | blank |
| command pool | blank unless forced |

Workers 2..N get `2`, `3`, ...

The banner shows the decision:

```text
4 workers (fork) for 120 spec files
TEST_ENV_NUMBER: "", 2, 3, 4
```

or:

```text
4 workers (fork) for 120 spec files
TEST_ENV_NUMBER: 1, 2, 3, 4
```

Provision blank-first databases:

```bash
bundle exec rake parallel:create
bundle exec turbo_tests --first-is-blank
```

Provision one-based databases:

```bash
PARALLEL_TEST_FIRST_IS_1=true bundle exec rake parallel:create
bundle exec turbo_tests --first-is-1
```

Project hooks can wrap the run:

```ruby
# Rakefile
namespace :turbo_tests do
  task :setup do
    Rake::Task["parallel:create"].invoke
  end

  task :cleanup do
    # collate reports, remove scratch files, etc.
  end
end
```

Disable them:

```bash
bundle exec turbo_tests --no-rake-hooks
```

## Coverage (SimpleCov)

Fork pool: a single merged report falls out of the preloader/fork setup when `SimpleCov.at_fork` is available.

Spawn and command pools: give each worker a command name and collate in cleanup:

```ruby
# spec/spec_helper.rb
require "simplecov"

SimpleCov.command_name("turbo_tests-#{ENV.fetch('TEST_ENV_NUMBER', 'blank')}")
SimpleCov.start
```

```ruby
# Rakefile
namespace :turbo_tests do
  task :cleanup do
    require "simplecov"
    SimpleCov.collate Dir["coverage/.resultset*.json"]
  end
end
```

## CI sharding

Use static groups to split across CI jobs:

```bash
bundle exec turbo_tests --groups 4 --only-group 1 --runtime-log tmp/parallel_runtime_rspec.log
bundle exec turbo_tests --groups 4 --only-group 2 --runtime-log tmp/parallel_runtime_rspec.log
bundle exec turbo_tests --groups 4 --only-group 3 --runtime-log tmp/parallel_runtime_rspec.log
bundle exec turbo_tests --groups 4 --only-group 4 --runtime-log tmp/parallel_runtime_rspec.log
```

Cache the runtime log as a CI artifact. On the next run, `turbo_tests` reads it, dispatches heavy files first, and records updated timings.


## Formatters

Built-ins:

```bash
bundle exec turbo_tests -f progress
bundle exec turbo_tests -f documentation
bundle exec turbo_tests -f json -o tmp/rspec.json
```

Custom formatters need `-r` and a formatter class name:

```bash
bundle exec turbo_tests -r fuubar -f Fuubar
bundle exec turbo_tests -r rspec_junit_formatter -f RspecJunitFormatter -o tmp/rspec.xml
```

Formatter names are constrained to loaded constant paths. Arbitrary expressions are not evaluated.

## When a worker will not exit

A stuck worker fails the run on purpose. The message names the worker and files:

```text
Worker 3 did not exit 60s after finishing RSpec; killed. Files: spec/models/user_spec.rb spec/jobs/sync_spec.rb
```

The worker writes a thread dump before it is killed:

```text
TurboTests diagnostics for pid 12345
Thread #<Thread:0x000... sleep> status=sleep native_thread_id=...
  spec/support/background_worker.rb:12:in `sleep'
  spec/support/background_worker.rb:12:in `block in start'
Live objects: Thread=8 IO=24
Open file descriptors: ...
```

Use a shorter timeout while reproducing:

```bash
bundle exec turbo_tests --exit-timeout 5
```

Add parent-side diagnostics when available:

```bash
bundle exec turbo_tests --diagnose
```

`--exit-timeout 0` waits forever and restores the old unbounded wait.

## FAQ

| Question | Answer |
|---|---|
| When is the seed printed? | When any worker reports random ordering was used. Defined-order suites do not print seed text. |
| Does `--seed` reproduce across workers? | Yes. One seed is shared through `TURBO_TESTS_SEED` and forwarded to RSpec when the user passes `--seed`. |
| Is `--profile` per worker? | No. Worker profile rows are merged into one top-N report. |
| Are deprecations repeated per worker? | No. Duplicate deprecations are replayed once in the parent. |
| Is "All examples were filtered out" repeated? | No. It is printed once. |
| Does Windows work? | Use spawn or command pools. Fork is Unix-only. |
| Does JRuby or TruffleRuby work? | Use spawn or command pools. Their CI legs are non-gating until green. |
| What about `turbo_tests2`? | v3 acknowledges the [`turbo_tests2`](https://github.com/galtzo-floss/turbo_tests2) fork and adopts the community PR ideas listed in the changelog. |

## Development

Install dependencies:

```bash
bundle install
```

Run tests:

```bash
bundle exec rspec
```

Dogfood the CLI:

```bash
bin/turbo_tests -n4 spec
```

Run local tools:

```bash
bin/benchmark              # serial rspec vs released 2.2.5 vs the local pools, median of 5
bin/leak_check             # 300 generated files through one long-lived worker; fails if RSS keeps growing
bin/check_ruby24_syntax    # parses lib/ and bin/ with the Ruby 2.4 grammar
```

`TURBO_TESTS_GC_STAT_EVERY=50` makes a worker run a full GC every 50 jobs and print `GC.stat` counters to stderr,
which tells retained objects apart from heap growth.

## Releasing

Maintainers only:

1. Bump `lib/turbo_tests/version.rb`.
2. Tag with the `tag_and_release` workflow.
3. Keep the 2.x line on `2-x-stable`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/serpapi/turbo_tests. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/serpapi/turbo_tests/blob/master/CODE_OF_CONDUCT.md).


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the TurboTests project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/serpapi/turbo_tests/blob/master/CODE_OF_CONDUCT.md).
