import Darwin
import Testing

@testable import CodexQuotaViewer

@Test
func runtimeSignalHandlersIgnoreSIGPIPE() {
    installRuntimeSignalHandlers()

    var action = sigaction()
    #expect(sigaction(SIGPIPE, nil, &action) == 0)

    let currentHandler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
    let ignoredHandler = unsafeBitCast(SIG_IGN, to: UInt.self)
    #expect(currentHandler == ignoredHandler)
}
