import Foundation
import SwiftUI

@MainActor
struct NoteExpressionSheet: View {
    let trackID: UUID
    let note: MelodyNote
    let canSlur: Bool
    let onApply: (NoteExpression) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expression: NoteExpression

    init(trackID: UUID, note: MelodyNote, canSlur: Bool, onApply: @escaping (NoteExpression) -> Void) {
        self.trackID = trackID
        self.note = note
        self.canSlur = canSlur
        self.onApply = onApply
        _expression = State(initialValue: note.expression)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连音与发音") {
                    Toggle("与前一音符连唱", isOn: $expression.slur)
                        .disabled(!canSlur && !expression.slur)
                        .accessibilityHint(canSlur ? "保留前一音符的发音并跨音高延唱。" : "前一音符必须紧邻当前音符才能连唱。")
                    Stepper(value: $expression.transitionMilliseconds, in: 0...250, step: 5) {
                        valueLabel("音高过渡", value: expression.transitionMilliseconds, unit: "ms")
                    }
                    Stepper(value: $expression.timingMilliseconds, in: -120...120, step: 5) {
                        valueLabel("发音提前量", value: expression.timingMilliseconds, unit: "ms")
                    }
                }

                Section("颤音") {
                    Stepper(value: $expression.vibratoDepth, in: 0...150, step: 5) {
                        valueLabel("深度", value: expression.vibratoDepth, unit: "音分")
                    }
                    HStack {
                        Text("速率")
                        Slider(value: $expression.vibratoRate, in: 3...9, step: 0.1)
                            .accessibilityLabel("颤音速率")
                        Text(String(format: "%.1f Hz", expression.vibratoRate))
                            .monospacedDigit().foregroundStyle(StudioTheme.muted).frame(width: 58, alignment: .trailing)
                    }
                }

                Section {
                    PitchCurveEditor(points: $expression.pitchCurve)
                        .frame(height: 170)
                } header: {
                    HStack {
                        Text("音高偏移")
                        Spacer()
                        Button("重置") { expression.pitchCurve = [] }
                            .disabled(expression.pitchCurve.isEmpty)
                    }
                } footer: {
                    Text("在图中拖动添加或调整音高点。纵轴单位为音分，横轴表示当前音符的时长。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(StudioTheme.backdrop.ignoresSafeArea())
            .navigationTitle("演唱调校")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onApply(normalized(expression)); dismiss() }
                        .disabled(!expression.isValid)
                }
            }
        }
        .tint(StudioTheme.accent)
    }

    private func valueLabel(_ label: String, value: Int, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value) \(unit)").monospacedDigit().foregroundStyle(StudioTheme.muted)
        }
    }

    private func normalized(_ value: NoteExpression) -> NoteExpression {
        var result = value
        result.pitchCurve = value.pitchCurve.sorted { $0.position < $1.position }
        return result
    }
}

private struct PitchCurveEditor: View {
    @Binding var points: [PitchPoint]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, _ in
                    let midY = size.height / 2
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: midY))
                    grid.addLine(to: CGPoint(x: size.width, y: midY))
                    for fraction in [CGFloat(0.25), 0.5, 0.75] {
                        grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                        grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                    }
                    context.stroke(grid, with: .color(StudioTheme.border.opacity(0.75)), lineWidth: 1)

                    let sorted = points.sorted { $0.position < $1.position }
                    if !sorted.isEmpty {
                        var curve = Path()
                        curve.move(to: point(for: sorted[0], in: size))
                        for value in sorted.dropFirst() { curve.addLine(to: point(for: value, in: size)) }
                        context.stroke(curve, with: .color(StudioTheme.accent), lineWidth: 2)
                    }
                    for value in sorted {
                        let location = point(for: value, in: size)
                        context.fill(Path(ellipseIn: CGRect(x: location.x - 5, y: location.y - 5, width: 10, height: 10)),
                                     with: .color(StudioTheme.accent))
                    }
                }
                .background(StudioTheme.background.opacity(0.76), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { update($0.location, in: size) })

                VStack {
                    HStack {
                        Text("+1200").font(.caption2).foregroundStyle(StudioTheme.muted)
                        Spacer()
                        Text("\(points.count)/32").font(.caption2.monospacedDigit()).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                    HStack {
                        Text("-1200").font(.caption2).foregroundStyle(StudioTheme.muted)
                        Spacer()
                        Text("时长").font(.caption2).foregroundStyle(StudioTheme.muted)
                    }
                }
                .padding(7).allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("音高偏移曲线")
            .accessibilityHint("拖动添加或调整音高偏移点")
        }
    }

    private func point(for value: PitchPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(value.position) * size.width,
                y: (1 - CGFloat((value.cents + 1200) / 2400)) * size.height)
    }

    private func update(_ location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let position = Double(min(1, max(0, location.x / size.width)))
        let cents = Double(min(1200, max(-1200, (1 - location.y / size.height) * 2400 - 1200)))
        if let index = points.indices.min(by: { abs(points[$0].position - position) < abs(points[$1].position - position) }),
           abs(points[index].position - position) < 0.04 {
            points[index].cents = cents
        } else if points.count < 32 {
            points.append(PitchPoint(position: position, cents: cents))
            points.sort { $0.position < $1.position }
        }
    }
}
