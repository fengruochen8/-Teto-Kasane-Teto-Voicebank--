import SwiftUI

@MainActor
struct PianoRoll: View {
    @ObservedObject var model: StudioModel
    @State private var drag: NoteDrag?

    static let accent = Color(red: 0.98, green: 0.68, blue: 0.42)
    private let naturalKeys: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    var body: some View {
        GeometryReader { geometry in
            let layout = RollLayout(size: geometry.size)
            Canvas { context, _ in
                drawGrid(context, layout: layout)
                drawNotes(context, layout: layout)
            }
            .background(Color(red: 0.09, green: 0.14, blue: 0.19))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5)
                .onChanged { updateDrag($0, layout: layout) }
                .onEnded { _ in commitDrag() })
            .simultaneousGesture(SpatialTapGesture().onEnded { tap($0.location, layout: layout) })
            .accessibilityLabel("4小节旋律网格")
            .accessibilityHint("点按添加音符，拖动移动音符")
        }
    }

    private func drawGrid(_ context: GraphicsContext, layout: RollLayout) {
        for pitch in MelodyProject.pitches {
            let y = layout.rowTop(pitch)
            let isNatural = naturalKeys.contains(pitch % 12)
            let key = CGRect(x: 0, y: y, width: layout.keys, height: layout.row)
            let row = CGRect(x: layout.keys, y: y, width: layout.size.width - layout.keys, height: layout.row)
            context.fill(Path(key), with: .color(isNatural ? .white.opacity(0.88) : .black.opacity(0.54)))
            if !isNatural { context.fill(Path(row), with: .color(.black.opacity(0.19))) }
            context.stroke(Path { line in
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: layout.size.width, y: y))
            }, with: .color(.white.opacity(pitch % 12 == 0 ? 0.29 : 0.08)), lineWidth: 0.7)
            if isNatural, layout.row >= 11 {
                context.draw(
                    Text(MelodyProject.noteName(pitch))
                        .font(.system(size: min(11, layout.row * 0.7), weight: .medium, design: .monospaced))
                        .foregroundColor(.black.opacity(0.8)),
                    at: CGPoint(x: layout.keys / 2, y: y + layout.row / 2)
                )
            }
        }

        for step in 0...MelodyProject.steps {
            let x = layout.x(step)
            let isBar = step.isMultiple(of: MelodyProject.stepsPerBar)
            let isBeat = step.isMultiple(of: MelodyProject.stepsPerBeat)
            context.stroke(Path { line in
                line.move(to: CGPoint(x: x, y: layout.header))
                line.addLine(to: CGPoint(x: x, y: layout.size.height))
            }, with: .color(.white.opacity(isBar ? 0.34 : isBeat ? 0.15 : 0.06)), lineWidth: isBar ? 1 : 0.6)

            if isBar, step < MelodyProject.steps {
                context.draw(
                    Text("\(step / MelodyProject.stepsPerBar + 1)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.66)),
                    at: CGPoint(x: x + 8, y: layout.header / 2), anchor: .leading
                )
            }
        }
    }

    private func drawNotes(_ context: GraphicsContext, layout: RollLayout) {
        for note in model.project.notes {
            let displayed = drag?.original.id == note.id ? (drag?.candidate ?? note) : note
            let rect = layout.rect(displayed)
            let selected = note.id == model.selectedID
            let outline = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(outline, with: .color(Self.accent.opacity(selected ? 1 : 0.73)))
            if selected { context.stroke(outline, with: .color(.white.opacity(0.85)), lineWidth: 1.3) }
            if rect.width > 23, rect.height > 13 {
                context.draw(
                    Text(displayed.lyric.isEmpty ? "ら" : displayed.lyric)
                        .font(.system(size: min(12, rect.height - 3), weight: .semibold))
                        .foregroundColor(.black),
                    at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading
                )
                if selected, rect.width > 35 {
                    let grip = CGRect(x: rect.maxX - 5, y: rect.midY - 3, width: 2, height: 6)
                    context.fill(Path(roundedRect: grip, cornerRadius: 1), with: .color(.black.opacity(0.45)))
                }
            }
        }
    }

    private func hit(_ point: CGPoint, layout: RollLayout) -> MelodyNote? {
        model.project.notes.first { layout.rect($0).insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func tap(_ point: CGPoint, layout: RollLayout) {
        guard drag == nil, point.y >= layout.header,
              point.y < layout.size.height, point.x >= 0, point.x < layout.size.width else { return }
        if let note = hit(point, layout: layout) {
            model.select(note)
        } else {
            let pitch = MelodyProject.pitches.upperBound - Int((point.y - layout.header) / layout.row)
            guard MelodyProject.pitches.contains(pitch) else { return }
            if point.x < layout.keys {
                model.audition(pitch: pitch)
            } else {
                let step = Int((point.x - layout.keys) / layout.step)
                model.add(start: step, pitch: pitch)
            }
        }
    }

    private func updateDrag(_ value: DragGesture.Value, layout: RollLayout) {
        if drag == nil {
            guard let note = hit(value.startLocation, layout: layout) else { return }
            let rect = layout.rect(note)
            let resizing = value.startLocation.x >= rect.maxX - min(11, rect.width / 3)
            model.selectedID = note.id
            drag = NoteDrag(original: note, candidate: note, resizing: resizing)
        }
        guard var current = drag else { return }
        let shift = Int((value.translation.width / layout.step).rounded())
        var candidate = current.original
        if current.resizing {
            candidate.length = max(1, min(MelodyProject.steps - candidate.start, candidate.length + shift))
        } else {
            let vertical = Int((value.translation.height / layout.row).rounded())
            candidate.start = max(0, min(MelodyProject.steps - candidate.length, candidate.start + shift))
            candidate.pitch = max(MelodyProject.pitches.lowerBound, min(MelodyProject.pitches.upperBound, candidate.pitch - vertical))
        }
        if model.project.canPlace(candidate) {
            current.candidate = candidate
            drag = current
        }
    }

    private func commitDrag() {
        defer { drag = nil }
        guard let drag, drag.candidate != drag.original else { return }
        if model.place(drag.candidate), drag.candidate.pitch != drag.original.pitch {
            model.audition(pitch: drag.candidate.pitch)
        }
    }
}

private struct NoteDrag {
    let original: MelodyNote
    var candidate: MelodyNote
    let resizing: Bool
}

private struct RollLayout {
    let size: CGSize
    let keys: CGFloat = 48
    let header: CGFloat = 26

    var row: CGFloat { max(1, (size.height - header) / CGFloat(MelodyProject.pitches.count)) }
    var step: CGFloat { max(1, (size.width - keys) / CGFloat(MelodyProject.steps)) }

    func x(_ index: Int) -> CGFloat { keys + CGFloat(index) * step }

    func rowTop(_ pitch: Int) -> CGFloat {
        header + CGFloat(MelodyProject.pitches.upperBound - pitch) * row
    }

    func rect(_ note: MelodyNote) -> CGRect {
        CGRect(x: x(note.start) + 1, y: rowTop(note.pitch) + 1,
               width: max(2, CGFloat(note.length) * step - 2), height: max(2, row - 2))
    }
}
