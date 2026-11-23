import SwiftUI

enum PianoKeyboardMode: Hashable {
    case audition
    case entry
}

@MainActor
struct PianoKeyboard: View {
    @Binding var isExpanded: Bool
    @Binding var mode: PianoKeyboardMode
    let location: String
    let onKey: (Int) -> Void

    private let keybedHeight: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                keyboard
                    .frame(height: keybedHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(StudioTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(StudioTheme.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.snappy(duration: 0.22), value: isExpanded)
    }

    private var header: some View {
        Group {
            if isExpanded {
                HStack(spacing: 10) {
                    title
                    StudioSegments(
                        selection: $mode, label: "键盘操作",
                        options: [(PianoKeyboardMode.audition, "试听"), (PianoKeyboardMode.entry, "录入")]
                    )
                    .frame(width: 126)

                    if mode == .entry {
                        Text(location)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(StudioTheme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityHint("点时间尺移动录入光标")
                    }

                    Spacer(minLength: 0)
                    Button {
                        isExpanded = false
                    } label: {
                        chevron("chevron.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收起钢琴键盘")
                }
            } else {
                Button {
                    isExpanded = true
                } label: {
                    HStack {
                        title
                        Spacer(minLength: 0)
                        chevron("chevron.up")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开钢琴键盘")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: isExpanded ? 40 : 36)
        .background(StudioTheme.raised)
    }

    private var title: some View {
        Label("钢琴键盘", systemImage: "pianokeys")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(StudioTheme.ink)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(StudioTheme.secondary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    private var keyboard: some View {
        GeometryReader { geometry in
            let pitches = Array(MelodyProject.pitches)
            let whiteKeys = pitches.filter { isWhiteKey($0) }
            let blackKeys = pitches.filter { !isWhiteKey($0) }
            let whiteWidth = geometry.size.width / CGFloat(whiteKeys.count)
            let blackWidth = whiteWidth * 0.62
            let blackHeight = geometry.size.height * 0.62

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(whiteKeys, id: \.self) { midi in
                        keyboardButton(midi, black: false)
                            .frame(width: whiteWidth, height: geometry.size.height)
                    }
                }

                ForEach(blackKeys, id: \.self) { midi in
                    let precedingWhite = whiteKeys.firstIndex(of: midi - 1) ?? 0
                    let idealX = CGFloat(precedingWhite + 1) * whiteWidth - blackWidth / 2
                    let x = min(max(0, idealX), geometry.size.width - blackWidth)
                    keyboardButton(midi, black: true)
                        .frame(width: blackWidth, height: blackHeight)
                        .offset(x: x)
                        .zIndex(1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("钢琴键盘")
    }

    @ViewBuilder
    private func keyboardButton(_ midi: Int, black: Bool) -> some View {
        Button {
            onKey(midi)
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !black && (midi % 12 == 0 || midi == MelodyProject.pitches.lowerBound) {
                    Text(MelodyProject.noteName(midi))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.62))
                        .padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PianoKeyStyle(isBlack: black, accent: PianoRoll.accent))
        .accessibilityLabel("\(MelodyProject.noteName(midi))，\(mode == .audition ? "试听" : "录入")")
        .accessibilityHint(black ? "黑键" : "白键")
    }

    private func isWhiteKey(_ midi: Int) -> Bool {
        [0, 2, 4, 5, 7, 9, 11].contains(midi % 12)
    }
}

private struct PianoKeyStyle: ButtonStyle {
    let isBlack: Bool
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isBlack ? StudioTheme.keyBlack : StudioTheme.keyWhite)
            .overlay {
                Rectangle()
                    .stroke(isBlack ? Color.white.opacity(0.16) : Color.black.opacity(0.16), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: isBlack ? 3 : 0, style: .continuous))
            .overlay {
                if configuration.isPressed {
                    accent.opacity(isBlack ? 0.8 : 0.62)
                        .clipShape(RoundedRectangle(cornerRadius: isBlack ? 3 : 0, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1, anchor: .top)
    }
}
