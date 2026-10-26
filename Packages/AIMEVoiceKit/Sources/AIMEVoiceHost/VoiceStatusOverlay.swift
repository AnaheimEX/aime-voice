// Adapted from Type4Me (MIT): UI/FloatingBar/FloatingBarPanel.swift,
// CompactAudioIndicator.swift, FloatingBarView.swift and UI/DesignSystem.swift.
// Copyright (c) 2026 Type4Me Contributors. See licenses/type4me.LICENSE.txt.

import AppKit
import Observation
import OSLog
import SwiftUI

/// Use the local Siri cue at both capture boundaries without blocking capture.
/// The system asset stays on the host Mac and is not redistributed with AIME.
@MainActor
enum VoiceRecordingCue {
    private static let logger = Logger(subsystem: "app.zool.aime.voice", category: "cue")
    private static let startSound = NSSound(contentsOfFile:
        "/System/Library/PrivateFrameworks/AssistantServices.framework/Resources/dt-begin.caf",
        byReference: false)
    private static let endSound = NSSound(contentsOfFile:
        "/System/Library/PrivateFrameworks/AssistantServices.framework/Resources/dt-confirm.caf",
        byReference: false)

    static func play(recording: Bool) {
        startSound?.stop()
        endSound?.stop()
        let sound = recording ? startSound : endSound
        let played = sound?.play() ?? false
        logger.notice("stage=recordingCue recording=\(recording) loaded=\(sound != nil) playbackAccepted=\(played)")
    }
}

/// Type4Me's compact, bottom-centered indicator. Never activates or accepts input.
@MainActor
final class VoiceStatusOverlay {
    enum State {
        case preparing, recording, transcribing, processing, rewriting, translating

        var label: String {
            switch self {
            case .preparing: "正在准备录音"
            case .recording: "正在录音"
            case .transcribing: "正在转译"
            case .processing: "正在润色"
            case .rewriting: "正在改写"
            case .translating: "翻译中…"
            }
        }
    }

    static let shared = VoiceStatusOverlay()

    private let model = VoiceOverlayModel()
    private let panel: VoiceOverlayPanel
    private var anchorDisplayID: CGDirectDisplayID?
    private static let shadowInset: CGFloat = 8
    private static let bottomOffset: CGFloat = 48

    private init() {
        // Keep the 180pt capsule width; use 44pt height and an 8pt shadow inset.
        let frame = NSRect(x: 0, y: 0, width: 196, height: 60)
        panel = VoiceOverlayPanel(contentRect: frame)
        let hosting = NSHostingView(rootView: VoiceOverlayContent(model: model))
        hosting.sizingOptions = []
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    func show(state: State) {
        if !panel.isVisible {
            model.level = 0
            model.sessionID = UUID()
            anchorDisplayID = Self.screenUnderMouse().flatMap(Self.displayID)
        }
        model.state = state
        let screen = NSScreen.screens.first { Self.displayID($0) == anchorDisplayID }
            ?? Self.screenUnderMouse()
        guard let screen else { return }
        anchorDisplayID = Self.displayID(screen)
        let size = panel.frame.size
        // Match Type4Me's pixel-aligned visible-frame positioning, above the Dock.
        panel.setFrame(NSRect(
            x: (screen.visibleFrame.midX - size.width / 2).rounded(),
            y: (screen.visibleFrame.minY + Self.bottomOffset - Self.shadowInset).rounded(),
            width: size.width, height: size.height
        ), display: panel.isVisible)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func updateLevel(_ level: Float) {
        guard panel.isVisible, model.state == .recording else { return }
        model.level = level.isFinite ? max(0, min(1, level)) : 0
    }

    func hide() {
        // Hide synchronously: a previous session cannot hide a newly started one.
        panel.orderOut(nil)
        model.level = 0
        model.state = .preparing
        anchorDisplayID = nil
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class VoiceOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
private final class VoiceOverlayModel {
    var state = VoiceStatusOverlay.State.preparing
    var level: Float = 0
    var sessionID = UUID()
}

private struct VoiceOverlayContent: View {
    let model: VoiceOverlayModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // Apple's Siri SAE artwork: gradient tile with a white ring and waveform.
    // Load the installed asset through public AppKit; do not execute framework code.
    private static let siriIcon: NSImage? = Bundle(
        path: "/System/Library/PrivateFrameworks/SiriUI.framework"
    )?.image(forResource: "SiriIconSAE")

    var body: some View {
        HStack(spacing: 8) {
            if let image = Self.siriIcon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            Group {
                if model.state == .recording {
                    VoiceCompactAudioIndicator(model: model)
                        .id(model.sessionID)
                } else {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                        Text(model.state.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(width: 180, height: 44)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(red: 17 / 255, green: 18 / 255, blue: 20 / 255))
            } else {
                ZStack {
                    shape.fill(Color.black.opacity(0.52))
                    Color.clear.glassEffect(.regular, in: shape)
                }
            }
        }
        .shadow(color: .black.opacity(0.20), radius: 3, x: 0, y: 1)
        .padding(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.state.label)
    }
}

private struct VoiceWaveSample {
    let height: CGFloat
    let isActive: Bool
}

/// Type4Me's rolling waveform, driven only by the actual microphone level.
@MainActor
private final class VoiceAudioHistory {
    var samples: [VoiceWaveSample] = []
    var lastSampleTime: TimeInterval = 0
    private let sampleInterval: TimeInterval = 0.13

    func update(currentTime: TimeInterval, level: Float) -> CGFloat {
        if lastSampleTime == 0 { lastSampleTime = currentTime }
        let elapsed = currentTime - lastSampleTime
        if elapsed >= sampleInterval {
            let steps = Int(elapsed / sampleInterval)
            for _ in 0..<min(steps, 10) {
                let normalized = max(0, min(1, CGFloat(level)))
                let silenceThreshold: CGFloat = 0.045
                let sample: VoiceWaveSample
                if normalized <= silenceThreshold {
                    sample = VoiceWaveSample(height: 2, isActive: false)
                } else {
                    let effective = (normalized - silenceThreshold) / (1 - silenceThreshold)
                    let gain = min(1, pow(effective, 0.95) * 0.85)
                    sample = VoiceWaveSample(height: min(18, max(3, 2 + gain * 16)), isActive: true)
                }
                samples.insert(sample, at: 0)
                if samples.count > 50 { samples.removeLast() }
            }
            lastSampleTime += Double(steps) * sampleInterval
        }
        return CGFloat(max(0, min(1, (currentTime - lastSampleTime) / sampleInterval)))
    }
}

private struct VoiceCompactAudioIndicator: View {
    let model: VoiceOverlayModel
    @State private var history = VoiceAudioHistory()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let fraction = history.update(
                    currentTime: timeline.date.timeIntervalSinceReferenceDate, level: model.level)
                let barWidth: CGFloat = 2
                let pitch: CGFloat = 4.5
                guard size.width >= barWidth else { return }
                let rightEdge = size.width - 1 - fraction * pitch
                let totalColumns = Int(ceil((size.width + pitch) / pitch)) + 1
                for index in 0..<totalColumns {
                    let x = rightEdge - CGFloat(index) * pitch
                    guard x >= -barWidth && x <= size.width else { continue }
                    let sample = index < history.samples.count
                        ? history.samples[index] : VoiceWaveSample(height: 2, isActive: false)
                    let rect = CGRect(x: x, y: (size.height - sample.height) / 2,
                                      width: barWidth, height: sample.height)
                    let color = sample.isActive
                        ? Color(red: 251 / 255, green: 251 / 255, blue: 251 / 255)
                        : Color(red: 138 / 255, green: 138 / 255, blue: 138 / 255)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .frame(height: 24)
    }
}
