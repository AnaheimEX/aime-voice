public import SwiftUI

/// Host-owned colors. The voice module owns its layout and interactions.
public struct VoiceSettingsStyle: Sendable {
    public let accent: Color
    public let canvas: Color
    public let card: Color
    public let cardBorder: Color
    public let warning: Color
    public let success: Color

    public init(accent: Color, canvas: Color, card: Color, cardBorder: Color, warning: Color, success: Color) {
        self.accent = accent
        self.canvas = canvas
        self.card = card
        self.cardBorder = cardBorder
        self.warning = warning
        self.success = success
    }
}

extension EnvironmentValues {
    @Entry var voiceSettingsStyle = VoiceSettingsStyle(
        accent: .accentColor, canvas: Color(.windowBackgroundColor), card: Color(.controlBackgroundColor),
        cardBorder: .primary.opacity(0.08), warning: .orange, success: .green)
}

struct VoicePaneHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(.white)
                .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }
}

