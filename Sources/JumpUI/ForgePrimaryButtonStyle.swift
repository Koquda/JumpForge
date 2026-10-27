import SwiftUI

struct ForgePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .foregroundStyle(ForgeStyle.background)
            .background(isEnabled ? ForgeStyle.lime : Color.gray, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.45))
    }
}
