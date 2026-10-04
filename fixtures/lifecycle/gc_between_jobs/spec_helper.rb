RSpec.configure do |config|
  config.after(:each) { GC.start }
  config.after(:suite) { GC.start }
end
