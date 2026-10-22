import AIMEVoiceHost
import InputMethodKit

/// The only bridge between the upstream input controller and the voice module.
@MainActor final class LocalVoiceAdapter: VoiceHost {
    private weak var engine: InputEngine?
    init(engine: InputEngine) { self.engine = engine }

    func snapshot(for owner: InputOwner) -> InputSnapshot? {
        guard let controller = engine?.activeController,
              controller.voiceOwner == owner,
              let client = controller.client() as? any IMKTextInput else { return nil }
        let clear = !controller.isComposing && controller.draft.isEmpty
        return InputSnapshot(client: client,
                             canStart: clear && controller.polish == nil && controller.quickMenu == nil,
                             canCommit: clear)
    }

    func present(_ effect: HostPresentation, for owner: InputOwner) {
        guard let engine, let controller = engine.activeController,
              controller.voiceOwner == owner else { return }
        switch effect {
        case .status(let text): engine.showStatus(text)
        case .hideCandidates: engine.panel.hide()
        case .restorePanel:
            engine.cancelStatus()
            controller.restorePanelAfterStatus()
        }
    }
}
