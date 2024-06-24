# Changelog

## [Unreleased](https://github.com/serpapi/turbo_tests/tree/HEAD)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.2.4...HEAD)

**Fixed bugs:**

- `turbo_tests` output missed one error compared and failed lines \(compared to RSpec output\) [\#40](https://github.com/serpapi/turbo_tests/issues/40)

**Closed issues:**

- Seed option is not passed to underlying rspec runners [\#56](https://github.com/serpapi/turbo_tests/issues/56)

## [v2.2.4](https://github.com/serpapi/turbo_tests/tree/v2.2.4) (2024-06-18)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.2.3...v2.2.4)

**Fixed bugs:**

- turbo\_tests is not working with Windows [\#38](https://github.com/serpapi/turbo_tests/issues/38)

**Merged pull requests:**

- Remove default `seed` value [\#48](https://github.com/serpapi/turbo_tests/pull/48) ([ilyazub](https://github.com/ilyazub))

## [v2.2.3](https://github.com/serpapi/turbo_tests/tree/v2.2.3) (2024-04-16)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.2.2...v2.2.3)

**Merged pull requests:**

- Remove `json` gem explicit dependency [\#54](https://github.com/serpapi/turbo_tests/pull/54) ([ilyazub](https://github.com/ilyazub))

## [v2.2.2](https://github.com/serpapi/turbo_tests/tree/v2.2.2) (2024-04-16)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.2.1...v2.2.2)

**Fixed bugs:**

- json v2.7.2 breaks turbo\_tests [\#52](https://github.com/serpapi/turbo_tests/issues/52)

**Merged pull requests:**

- Remove OpenStruct usage with Struct replacement [\#53](https://github.com/serpapi/turbo_tests/pull/53) ([javierjulio](https://github.com/javierjulio))
- Windows support [\#50](https://github.com/serpapi/turbo_tests/pull/50) ([deivid-rodriguez](https://github.com/deivid-rodriguez))

## [v2.2.1](https://github.com/serpapi/turbo_tests/tree/v2.2.1) (2024-04-10)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.2.0...v2.2.1)

**Merged pull requests:**

- Explicitely load ostruct so it's compatible with latest JSON gem [\#49](https://github.com/serpapi/turbo_tests/pull/49) ([lcmen](https://github.com/lcmen))

## [v2.2.0](https://github.com/serpapi/turbo_tests/tree/v2.2.0) (2023-09-29)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.1.1...v2.2.0)

**Fixed bugs:**

- undefined method `logger' for Async:Module [\#17](https://github.com/serpapi/turbo_tests/issues/17)

**Merged pull requests:**

- Is bundler a dependency of turbo tests? [\#42](https://github.com/serpapi/turbo_tests/pull/42) ([deivid-rodriguez](https://github.com/deivid-rodriguez))

## [v2.1.1](https://github.com/serpapi/turbo_tests/tree/v2.1.1) (2023-07-10)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.1.0...v2.1.1)

**Merged pull requests:**

- Quote 3.0 in the CI configuration to avoid truncation. [\#36](https://github.com/serpapi/turbo_tests/pull/36) ([petergoldstein](https://github.com/petergoldstein))
- Add seed parameter to turbo tests [\#33](https://github.com/serpapi/turbo_tests/pull/33) ([mRudzki](https://github.com/mRudzki))

## [v2.1.0](https://github.com/serpapi/turbo_tests/tree/v2.1.0) (2023-05-26)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v2.0.0...v2.1.0)

**Merged pull requests:**

- Set bundler environmental variables when they are provided [\#35](https://github.com/serpapi/turbo_tests/pull/35) ([hsbt](https://github.com/hsbt))

## [v2.0.0](https://github.com/serpapi/turbo_tests/tree/v2.0.0) (2023-05-17)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.4.1...v2.0.0)

**Implemented enhancements:**

- \[CI/CD\] Tag release on version.rb change [\#30](https://github.com/serpapi/turbo_tests/pull/30) ([ilyazub](https://github.com/ilyazub))

**Closed issues:**

- Compatibility with parallel\_tests v4 [\#28](https://github.com/serpapi/turbo_tests/issues/28)

**Merged pull requests:**

- Add turbo-tests logo [\#32](https://github.com/serpapi/turbo_tests/pull/32) ([dimitryzub](https://github.com/dimitryzub))
- \[CI\] Run tests on all pull requests [\#31](https://github.com/serpapi/turbo_tests/pull/31) ([ilyazub](https://github.com/ilyazub))
- Claim compatibility with parallel\_tests v4 [\#29](https://github.com/serpapi/turbo_tests/pull/29) ([franzliedke](https://github.com/franzliedke))

## [v1.4.1](https://github.com/serpapi/turbo_tests/tree/v1.4.1) (2023-02-15)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.4.0...v1.4.1)

**Merged pull requests:**

- fix: don't duplicate blank `extra_failure_lines` [\#26](https://github.com/serpapi/turbo_tests/pull/26) ([ilyazub](https://github.com/ilyazub))

## [v1.4.0](https://github.com/serpapi/turbo_tests/tree/v1.4.0) (2023-01-20)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.3.0...v1.4.0)

**Closed issues:**

- Rails.application is nil in spec\_helper.rb [\#22](https://github.com/serpapi/turbo_tests/issues/22)

**Merged pull requests:**

- fix: support reporting extra failure lines [\#25](https://github.com/serpapi/turbo_tests/pull/25) ([ilyazub](https://github.com/ilyazub))

## [v1.3.0](https://github.com/serpapi/turbo_tests/tree/v1.3.0) (2021-10-04)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.2.5...v1.3.0)

**Merged pull requests:**

- Add --runtime-log option [\#16](https://github.com/serpapi/turbo_tests/pull/16) ([AMHOL](https://github.com/AMHOL))

## [v1.2.5](https://github.com/serpapi/turbo_tests/tree/v1.2.5) (2021-08-17)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.2.4...v1.2.5)

**Fixed bugs:**

- NoMethodError: undefined method `pending\_exception' for TurboTests::FakeExecutionResult [\#6](https://github.com/serpapi/turbo_tests/issues/6)

**Merged pull requests:**

- Fix reporting of pending exceptions [\#15](https://github.com/serpapi/turbo_tests/pull/15) ([ilyazub](https://github.com/ilyazub))

## [v1.2.4](https://github.com/serpapi/turbo_tests/tree/v1.2.4) (2021-03-25)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.2.3...v1.2.4)

## [v1.2.3](https://github.com/serpapi/turbo_tests/tree/v1.2.3) (2021-03-25)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.2.2...v1.2.3)

**Fixed bugs:**

- When a exception is raised out of specs or code, tests are marked as successful [\#5](https://github.com/serpapi/turbo_tests/issues/5)

**Merged pull requests:**

- Fail tests on errors outside of examples [\#10](https://github.com/serpapi/turbo_tests/pull/10) ([ilyazub](https://github.com/ilyazub))

## [v1.2.2](https://github.com/serpapi/turbo_tests/tree/v1.2.2) (2021-03-02)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.2.0...v1.2.2)

**Implemented enhancements:**

- Capture time to load files [\#1](https://github.com/serpapi/turbo_tests/issues/1)

**Fixed bugs:**

- Documentation formatter is missing nesting/context lines [\#3](https://github.com/serpapi/turbo_tests/issues/3)

**Merged pull requests:**

- Monitor security vulnerabilities in dependencies [\#9](https://github.com/serpapi/turbo_tests/pull/9) ([ilyazub](https://github.com/ilyazub))
- Fix: Loading time summary not being reflected in the report [\#8](https://github.com/serpapi/turbo_tests/pull/8) ([smileart](https://github.com/smileart))
- Fix: Doc formatter contexts [\#7](https://github.com/serpapi/turbo_tests/pull/7) ([smileart](https://github.com/smileart))

## [v1.2.0](https://github.com/serpapi/turbo_tests/tree/v1.2.0) (2020-11-23)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.1.1...v1.2.0)

## [v1.1.1](https://github.com/serpapi/turbo_tests/tree/v1.1.1) (2020-10-30)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.1.0...v1.1.1)

## [v1.1.0](https://github.com/serpapi/turbo_tests/tree/v1.1.0) (2020-10-30)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/v1.0.0...v1.1.0)

## [v1.0.0](https://github.com/serpapi/turbo_tests/tree/v1.0.0) (2020-10-29)

[Full Changelog](https://github.com/serpapi/turbo_tests/compare/f431af94589a4dd0412df70679b389401e2179f5...v1.0.0)



\* *This Changelog was automatically generated by [github_changelog_generator](https://github.com/github-changelog-generator/github-changelog-generator)*
