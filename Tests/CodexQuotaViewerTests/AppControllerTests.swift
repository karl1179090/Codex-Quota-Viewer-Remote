import AppKit
import Testing

@testable import CodexQuotaViewer

@MainActor
@Test
func terminateRemoteCodexCheckboxDefaultsOn() {
    let checkbox = makeTerminateRemoteCodexProcessesCheckbox()

    #expect(checkbox.state == .on)
}
