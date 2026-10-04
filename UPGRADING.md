# Upgrading

## From 2.x to 3.0

| Change | What you see | How to get the old behaviour |
|---|---|---|
| Runtime log always used and recorded | Existing `tmp/turbo_rspec_runtime.log` or `tmp/parallel_runtime_rspec.log` affects every run, including path-selected runs. A log is written after runs. | Pass `--no-runtime-log`, or delete the log before a run. |
| Dynamic scheduling is default | Workers pull files from a shared largest-first queue. Output is still one RSpec stream. | Pass `--static` for one static group per worker. |
| Fork pool is default on MRI Unix | One preloader boots and forks workers. Startup-sensitive suites boot less often. | Pass `--pool spawn` for long-lived spawned workers, or `--pool command --static` for v2-style one-command-per-group execution. |
| Bounded shutdown fails the run | A worker that finished RSpec but will not exit prints diagnostics, is killed, and returns status 1. | Pass `--exit-timeout 0` to wait forever. |
| One shared seed | Random-order suites print one seed. `--seed SEED` reproduces across workers. | No v2-compatible multi-seed mode. Use `--seed` to reproduce. |
| `--` passthrough | Options after `--` go to RSpec. Unknown options before `--` still fail fast. | Put turbo_tests options before `--`; put RSpec-only options after it. |
| Formatter lookup is restricted | `-f` accepts built-ins or formatter class constants loaded by `-r`. Expressions are rejected. | Add `-r formatter_gem` and use `-f FormatterClass`. |
| `TEST_ENV_NUMBER` auto-detect | Banner prints `TEST_ENV_NUMBER: "", 2, 3` or `1, 2, 3`. Ambiguous ActiveRecord probes abort with instructions. | Pass `--first-is-1`, `--first-is-blank`, or set `PARALLEL_TEST_FIRST_IS_1=true`. |
| Ruby floor moves from 2.7 (2.x) to 2.4 | The gemspec accepts 2.4–2.6 for parity with `turbo_tests2`. The CI matrix is configured to run them on Linux and the syntax gate parses `lib/` and `bin/` with the 2.4 grammar; runtime compatibility there is unverified until that matrix has run. | Nothing to restore; 2.x required 2.7. |
| `parallel_tests` runtime dependency removed | `ParallelTests` constants are not loaded by turbo_tests. | Add `parallel_tests` to your Gemfile if app/test code references `ParallelTests` directly. Prefer replacing those references with env vars or rake hooks. |
| `-r` runs in the parent | Required files load before formatter lookup and before the run starts. | Require spec-only files after `--` through RSpec options when they should load in workers. |
| `--test-options` is split as one shell string | `--test-options "--tag focus --format documentation"` appends RSpec options. | Prefer `-- --tag focus --format documentation` for new commands. |
| Interrupted runs exit 130 | A single Ctrl-C lets workers finish their current example, prints the summary and exits `130`; a second Ctrl-C kills them. `SIGTERM` exits `143`. | None; CI wrappers can now tell an interrupted run from failing tests. |
| Command pool needs `--groups` ≤ `-n` | `--pool command` (also selected by `RSPEC_EXECUTABLE`) runs one `rspec` per static group and refuses more groups than workers. | Use `--pool spawn --static` for more groups than workers. |
| Programmatic API kept | `TurboTests::Runner.run(hash)` still accepts the v2 hash shape and maps it to options. | No change needed for supported keys. Unknown keys now raise `ArgumentError`. |

## Checklist for Rails apps

- Add `.turbo_tests.rb` when the app opens connections, clients, or thread pools before fork.
- Pick a database naming convention: blank first (`test`, `test2`) or one-based (`test1`, `test2`).
- Provision with `bundle exec rake parallel:create` or `PARALLEL_TEST_FIRST_IS_1=true bundle exec rake parallel:create`.
- Pass `--first-is-blank` or `--first-is-1` in CI if auto-detect cannot safely connect.
- For SimpleCov in fork pool, use `SimpleCov.at_fork` when available.
- For SimpleCov in spawn/command pools, set `SimpleCov.command_name` per worker and collate in `turbo_tests:cleanup`.
- For `pg` fork issues, try `PGGSSENCMODE=disable` and reconnect in `after_fork`.
- Use `--pool command --static` while isolating fork-safety issues.

## From 2.2.5 to 2.2.6

2.2.6 is a fixes-only 2.x release. It keeps `parallel_tests` and does not change the scheduler or pool model.

| Change | What you see | How to get the old behaviour |
|---|---|---|
| Hung subprocess containment | A subprocess that finished RSpec but never exited is asked to dump threads, then terminated and killed after `--exit-timeout` seconds. The run names the process/files and exits 1. | Pass `--exit-timeout 0`. |
| Binary-safe output | Non-ASCII output and binary exception strings no longer crash the reader under US-ASCII locales. | No old behaviour needed. |
| Shared seed | Suites that enable random ordering are reproducible and print `Randomized with seed`. Defined-order suites print no seed. Explicit `--seed` works as before. | No old behaviour needed. |
| Runtime log with explicit paths | Recorded runtimes are used beyond bare `spec`; logs are recorded for whole-suite runs and whenever `--runtime-log` is given. | Remove the log or omit `--runtime-log`. |
| Fail-fast and interrupts kill subprocesses | `--fail-fast` interrupts subprocesses. A second Ctrl-C kills them and exits 130 instead of printing a backtrace. | No old behaviour needed. |
| Empty groups | A group with no files no longer breaks exit-status computation. | No old behaviour needed. |
| `parallel_tests` 5.x allowed | Bundles can resolve `parallel_tests < 6`. | Pin `parallel_tests` lower in your Gemfile if needed. |
| CI matrix fixed | Declared OS matrix actually runs on those operating systems and includes Ruby 3.4. | No app action. |
