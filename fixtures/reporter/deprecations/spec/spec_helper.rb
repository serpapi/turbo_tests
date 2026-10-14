module DeprecatedHelper
  def call_deprecated_helper
    RSpec.deprecate("foo", replacement: "bar")
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.include DeprecatedHelper
end
