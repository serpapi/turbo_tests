# The preloader dies right after forking its first worker (before it can
# report it): the parent must report the other workers as crashed, kill the
# orphan and exit nonzero.
module TurboTestsFixtureDieAfterFirstFork
  def fork(*args, &block)
    pid = super
    Process.kill(:KILL, Process.pid) if pid
    pid
  end
end
Process.singleton_class.prepend(TurboTestsFixtureDieAfterFirstFork)
