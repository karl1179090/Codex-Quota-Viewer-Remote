import Darwin

func installRuntimeSignalHandlers() {
    _ = signal(SIGPIPE, SIG_IGN)
}
