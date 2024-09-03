RSpec.configure do |config|
  config.order = :defined
  Kernel.srand config.seed
end
