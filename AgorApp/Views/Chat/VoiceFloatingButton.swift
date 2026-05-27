import SwiftUI
import UIKit

struct VoiceFloatingButton: View {
    let voiceState: ContinuousVoiceService.State
    let action: () -> Void

    private var backgroundColor: Color {
        switch voiceState {
        case .listening, .recording:
            return .blue
        case .preparing, .transcribing, .sending, .speaking:
            return .orange
        case .paused, .disabled:
            return .gray
        }
    }

    private var iconName: String {
        switch voiceState {
        case .listening, .recording:
            return "mic.fill"
        case .preparing:
            return "waveform"
        case .speaking:
            return "speaker.wave.2.fill"
        case .transcribing, .sending:
            return "waveform"
        case .paused, .disabled:
            return "mic.slash.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                Text("Back to Voice")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(backgroundColor, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
    }
}

// MARK: - UIKit window overlay (above sheets/navigation)

/// UIWindow that passes through touches landing on its transparent background,
/// so only interactive subviews (buttons) capture events.
final class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else { return nil }
        return rootViewController?.view == hitView ? nil : hitView
    }
}

/// SwiftUI content rendered inside the overlay window.
struct VoiceOverlayContent: View {
    let chatVM: ChatViewModel
    let onNavigate: (String) -> Void

    var body: some View {
        if chatVM.shouldShowVoiceFloatingButton, let id = chatVM.voiceSessionId {
            VoiceFloatingButton(voiceState: chatVM.voiceService?.state ?? .disabled) {
                onNavigate(id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 16)
            .padding(.top, 60)
        }
    }
}

/// ViewModifier that mounts a PassThroughWindow above all app content,
/// including sheets and navigation controllers.
struct VoiceOverlayModifier: ViewModifier {
    let chatVM: ChatViewModel
    let onNavigate: (String) -> Void
    @State private var overlayWindow: PassThroughWindow?

    func body(content: Content) -> some View {
        content
            .onChange(of: chatVM.voiceModeEnabled) { _, enabled in
                if enabled { ensureWindow() } else { tearDown() }
            }
            .onChange(of: chatVM.voiceSessionId) { _, id in
                if id != nil { ensureWindow() } else { tearDown() }
            }
            .onAppear {
                if chatVM.voiceModeEnabled && chatVM.voiceSessionId != nil { ensureWindow() }
            }
            .onDisappear { tearDown() }
    }

    private func ensureWindow() {
        guard overlayWindow == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
               .compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let w = PassThroughWindow(windowScene: scene)
        // Level just below system status bar — above all in-app sheets and modals
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue - 1)
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: VoiceOverlayContent(chatVM: chatVM, onNavigate: onNavigate))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        overlayWindow = w
    }

    private func tearDown() {
        overlayWindow?.isHidden = true
        overlayWindow = nil
    }
}

extension View {
    func voiceFloatingOverlay(chatVM: ChatViewModel, onNavigate: @escaping (String) -> Void) -> some View {
        modifier(VoiceOverlayModifier(chatVM: chatVM, onNavigate: onNavigate))
    }
}
