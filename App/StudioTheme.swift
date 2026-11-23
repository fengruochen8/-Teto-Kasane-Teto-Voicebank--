import SwiftUI

enum StudioTheme {
    static let background = Color(red: 0.063, green: 0.059, blue: 0.122)
    static let backgroundTop = Color(red: 0.126, green: 0.091, blue: 0.199)
    static let surface = Color(red: 0.099, green: 0.083, blue: 0.169)
    static let raised = Color(red: 0.142, green: 0.114, blue: 0.225)
    static let border = Color(red: 0.273, green: 0.220, blue: 0.388)
    static let ink = Color(red: 0.967, green: 0.944, blue: 1.000)
    static let muted = Color(red: 0.727, green: 0.679, blue: 0.826)
    static let accent = Color(red: 1.000, green: 0.661, blue: 0.828)
    static let secondary = Color(red: 0.729, green: 0.660, blue: 1.000)
    static let playhead = Color(red: 0.596, green: 0.852, blue: 1.000)
    static let keyWhite = Color(red: 0.930, green: 0.898, blue: 0.977)
    static let keyBlack = Color(red: 0.082, green: 0.072, blue: 0.146)
    static let roll = Color(red: 0.091, green: 0.078, blue: 0.167)

    static let backdrop = LinearGradient(colors: [backgroundTop, background], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let actionGradient = LinearGradient(colors: [accent, secondary], startPoint: .leading, endPoint: .trailing)
}

extension View {
    func studioPanel(radius: CGFloat = 14) -> some View {
        background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(StudioTheme.border.opacity(0.75), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct StudioButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(prominent: Bool = false) {
        self.prominent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .foregroundStyle(prominent ? StudioTheme.background : StudioTheme.ink)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if prominent {
                    shape.fill(StudioTheme.actionGradient)
                } else {
                    shape.fill(StudioTheme.raised)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(prominent ? .white.opacity(0.20) : StudioTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.40)
    }
}

struct StudioSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let label: String
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let active = selection == option.value
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.subheadline.weight(active ? .semibold : .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(active ? StudioTheme.background : StudioTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(active ? StudioTheme.secondary : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .background(StudioTheme.background.opacity(0.70), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}