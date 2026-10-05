# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [3.0.0] - unreleased

### Added

- Added native `--pattern`, `--exclude-pattern`, and `--group-by runtime|filesize|found`, adopting ideas from #41 by inkstak; closes #77.
- Added `--only-group` and `--groups` static shard selection; closes #2.
- Added `--default-path`; closes #13.
- Added RSpec passthrough after `--` and `--test-options`; closes #14.
- Added `--only-failures` and `--next-failure` support; closes #43. The status file (`config.example_status_persistence_file_path`) is written once per run by the parent with rspec's merge semantics, instead of by every worker after every file: rspec rewrites the whole file under an exclusive lock, so per-file writes were quadratic in the number of recorded examples and serialised the workers on the lock (1.1 s per write at 127k recorded examples on a 1,645-file Rails suite).
- Added `turbo_tests:setup` and `turbo_tests:cleanup` rake hooks from #82 by G-Rath; closes #18.
- Added database setup guidance and rake-hook replacement for `--create`, adopting the intent of #21 by tradiff; closes #18.
- Added `--print-failed-group`, adopting #34 by mRudzki.
- Added `--nice`, adopting #44 by Bo98.
- Added `.rspec_parallel` / `spec/parallel_spec.opts` compatibility, adopting #45 by Bo98.
- Added process interrupt handling in the new supervisor, adopting #46 by Bo98.
- Added custom formatter support, including Fuubar counts from #51 by inkstak and JUnit-compatible fake examples from #78 by phoffer; closes #23.
- Added richer JSON rows for formatter compatibility, including ideas from tines.
- Added `--pool auto|fork|spawn|command`, with fork preloading on MRI Unix and spawn/command fallbacks for Windows, JRuby, and TruffleRuby.
- Added bounded shutdown diagnostics with worker thread dumps, parent diagnostics, and nonzero exit for hung workers.
- Added `TEST_ENV_NUMBER` auto-detection plus `--first-is-1` and `--first-is-blank`; closes #12.
- Added SimpleCov fork support and spawn/command collation recipes; closes #24.
- Added hand-curated changelog, superseding generated changelog work from #59 by gutoarraes; closes #11.
- Added Ruby 3.4 CI coverage, adopting #79 by willnet.
- Added CI compatibility work related to `parallel_tests` 5.x from #80 by marcrohloff for the 2.x line, while v3 removes the runtime dependency.
- Added acknowledgement of the `turbo_tests2` fork and pboling's work; closes #83.

### Changed

- Runtime logs are read whenever present and recorded by default, adopting fixes independently seen in OpenProject, crohr, and ruby-core; closes #27.
- Scheduler default changed from static groups to a dynamic per-file queue ordered by recorded runtime.
- Worker default changed from cold command processes to a fork preloader on MRI Unix.
- Seed handling uses one parent-selected seed and prints it only when random ordering is used, adopting aprescott's seed work from #60/#63; closes #60.
- Profile output is merged into one global top-N report; closes #39.
- Deprecations and filtered-out/no-example messages are deduplicated in the parent; closes #58.
- Formatter lookup now accepts built-ins or loaded formatter class constants only.
- `--verbose` keeps per-worker command/env output and adds pool, scheduler, and probe decisions.
- Ruby requirement is `>= 2.4` (2.x: `>= 2.7`), matching `turbo_tests2`; 2.4–2.6 are in the configured Linux CI matrix and the 2.4 syntax gate, with runtime compatibility unverified until that matrix has run.
- RSpec discovery is owned directly through `rspec-core`; `.rspec`, `.rspec-local`, `SPEC_OPTS`, `--pattern`, `--exclude-pattern`, and `path:line` selectors are preserved.
- Runtime log, seed, and encoding fixes incorporate reports and fixes from timezest, itsmycargo, crohr, OpenProject, ruby-core, and the `turbo_tests2` fork.
- README rewritten around the 3.0 runner, with a verbatim run as the first thing on the page; the externally hosted illustration is replaced by an in-repo mark (`assets/logo.svg`, dark variant) that shows four workers under one line of output.
- The gem no longer ships `fixtures/`, `assets/` and `.github/`; the gemspec summary, description and `changelog_uri` describe 3.0.

### Fixed

- Fixed subprocesses that finished RSpec but never exited hanging the entire run.
- Fixed invalid byte sequence crashes under US-ASCII locales, adopting the #65 class of fix and turbo_tests2 hardening; closes #65.
- Fixed JSON row generation for binary strings and non-UTF-8 exception data.
- Fixed fail-fast cancelling reader threads without terminating worker processes.
- Fixed worker-exited-without-results detection, adopting turbo_tests2 hardening.
- Fixed runtime log selection inconsistencies between counting and grouping.
- Fixed custom formatter example metadata for IDs, run time, exception class/cause, file path, line number, and group notifications.
- Fixed `All examples were filtered out` being printed once per worker.
- Fixed profile output being emitted once per worker instead of once per run.

### Removed

- Removed the `parallel_tests` runtime dependency.
- Declined #19 (DRb instead of pipes): DRb is synchronous RPC with a server thread per process and `Marshal.load` of peer data, it does nothing for a worker that will not exit, and `drb` is a bundled gem since Ruby 3.4; results stay JSON rows over pipes. Ractors, Marshal frames and threads are weighed in the README's "Alternatives considered".
- Removed arbitrary formatter constant evaluation through unrestricted `Kernel.const_get`.

Measurements: see the README's "How it works" section (`bin/benchmark`, `bin/leak_check`).

## [2.2.6] - unreleased

Fixes-only release for the 2.x line. No new default behaviour apart from the
hang containment below.

### Fixed

- A subprocess that finished RSpec but never exited used to hang the whole run
  forever (the `exit` message was only sent on EOF). After `--exit-timeout`
  seconds (default 60) the process is now asked to dump its threads (`SIGUSR1`,
  handled by the formatter inside the subprocess), then terminated and killed;
  the run reports which process and files were involved and exits with status 1.
  Pass `--exit-timeout 0` to restore the old unbounded wait.
- Subprocess output is read as binary and rows are scrubbed to valid UTF-8, so
  non-ASCII output or exception messages no longer crash the reader under a
  US-ASCII locale (#65) and JSON generation no longer raises on binary strings.
- All subprocesses share one seed. When the suite enables random ordering itself
  (`config.order = :random`), the run is reproducible and `Randomized with seed`
  is printed again (#60); when ordering is defined nothing is printed, and an
  explicit `--seed` behaves as before.
- Recorded runtimes are used for every invocation, not only for a bare `spec`
  argument; parallel_tests decides whether the log has enough data. The log is
  recorded for whole-suite runs and whenever `--runtime-log` is given (#27).
- `--fail-fast` now interrupts the subprocesses instead of only the threads
  reading them; a second `Ctrl-C` while waiting for subprocesses kills them and
  exits with status 130 instead of a backtrace.
- A group with no files no longer breaks the exit-status computation.

### Changed

- `parallel_tests` 5.x is allowed (`< 6`).
- CI runs the matrix on the declared operating systems (the Windows entries
  never actually ran on Windows) and adds Ruby 3.4.

## [2.2.5] - 2025-03-10

See https://github.com/serpapi/turbo_tests/releases for earlier releases.
