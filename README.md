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

## Installation

Add this line to your application's `Gemfile`:

```ruby
gem 'turbo_tests'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install turbo_tests
```

## Usage

Execute tests:

```bash
$ bundle exec turbo_tests
```

Show help:

```bash
$ bundle exec turbo_tests -h
Usage: turbo_tests [options]

[optional] Only selected files & folders:
  turbo_tests spec/bar spec/baz/xxx_spec.rb

Options:
    -n [PROCESSES]                   How many processes to use, default: available CPUs
    -r, --require PATH               Require a file.
    -f, --format FORMATTER           Choose a formatter. Available formatters: progress (p), documentation (d). Default: progress
    -t, --tag TAG                    Run examples with the specified tag.
    -o, --out FILE                   Write output to a file instead of $stdout
        --runtime-log FILE           Location of previously recorded test runtimes
    -v, --verbose                    More output
        --fail-fast=[N]
        --seed SEED                  Seed for rspec
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/serpapi/turbo_tests. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/serpapi/turbo_tests/blob/master/CODE_OF_CONDUCT.md).


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the TurboTests project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/serpapi/turbo_tests/blob/master/CODE_OF_CONDUCT.md).
