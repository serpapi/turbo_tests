# Passes, but the process can never exit: Ruby kills every thread on exit and
# waits for it, and this thread's ensure blocks forever (survives SIGTERM too).
Thread.new do
  begin
    sleep
  ensure
    sleep
  end
end

RSpec.describe "stuck at exit" do
  it("passes") { expect(1).to eq(1) }
end
