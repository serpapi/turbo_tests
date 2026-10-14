# Loaded by TurboTests::Reporter.formatter_class("ReporterSpecAutoloadedFormatter")
# the way RSpec loads `--format Fuubar` (require "fuubar").
class ReporterSpecAutoloadedFormatter
  RSpec::Core::Formatters.register self, :example_passed

  def initialize(output)
    @output = output
  end

  def example_passed(_notification)
    @output.print("+")
  end
end
