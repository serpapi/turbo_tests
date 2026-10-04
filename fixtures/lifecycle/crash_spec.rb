RSpec.describe "crash" do
  it("dies without reporting") { Process.kill(:KILL, Process.pid) }
end
