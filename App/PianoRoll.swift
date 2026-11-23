import SwiftUI

enum PianoRollTool: Hashable {
    case select
    case draw
}

enum GridSnap: Int, Hashable, CaseIterable {
    case sixteenth = 1
    case eighth = 2
    case quarter = 4

    func floor(_ step: CGFloat) -> Int {
        Int((step / CGFloat(rawValue)).rounded(.down)) * rawValue
    }

    func nearest(_ step: CGFloat) -> Int {
        Int((step / CGFloat(rawValue)).rounded()) * rawValue
    }
}

@MainActor
struct PianoRoll: View {
    @ObservedObject var model: StudioModel
    let trackID: UUID
    let showsEntryCursor: Bool
    let tool: PianoRollTool
    let snap: GridSnap
    @State private var drag: NoteDrag?
    @State private var drawing: MelodyNote?

    static let accent = StudioTheme.accent
    private let naturalKeys: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    var body: some View {
        GeometryReader { geometry in
            let layout = RollLayout(size: geometry.size)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isPlaying)) { _ in
                let playback = model.playbackPosition
                Canvas { context, _ in
                    drawGrid(context, layout: layout)
                    drawNotes(context, layout: layout)
                    let transport = Double(model.transportStep)
                    if let playback {
                        drawCursor(context, layout: layout, step: playback, color: StudioTheme.playhead, width: 2)
                    } else if showsEntryCursor {
                        if model.entryStep != model.transportStep {
                            drawCursor(context, layout: layout, step: transport, color: .white.opacity(0.48), width: 1)
                        }
                        drawCursor(context, layout: layout, step: Double(model.entryStep), color: Self.accent, width: 1.5)
                    } else {
                        drawCursor(context, layout: layout, step: transport, color: StudioTheme.playhead.opacity(0.72), width: 1.5)
                    }
                }
            }
            .background(StudioTheme.roll)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(StudioTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { dragChanged($0, layout: layout) }
                    .onEnded { _ in commitDrag() }
                    .exclusively(before: SpatialTapGesture().onEnded { tap($0.location, layout: layout) })
            )
            .accessibilityLabel("4小节旋律网格")
            .accessibilityHint(tool == .select ? "点选音符。点时间尺定位。" : "点空白网格添加音符。拖动设置时值。")
        }
    }

    private func drawGrid(_ context: GraphicsContext, layout: RollLayout) {
        let ruler = CGRect(x: 0, y: 0, width: layout.size.width, height: layout.header)
        context.fill(Path(ruler), with: .color(StudioTheme.raised))
        let activePitch = drag?.candidate.pitch ?? drawing?.pitch ?? model.selected?.pitch
        for pitch in MelodyProject.pitches {
            let y = layout.rowTop(pitch)
            let isNatural = naturalKeys.contains(pitch % 12)
            let pitchSelected = pitch == activePitch
            let key = CGRect(x: 0, y: y, width: layout.keys, height: layout.row)
            let row = CGRect(x: layout.keys, y: y, width: layout.size.width - layout.keys, height: layout.row)
            let keyColor = pitchSelected ? Self.accent : isNatural ? StudioTheme.keyWhite : StudioTheme.keyBlack
            context.fill(Path(key), with: .color(keyColor))
            if !isNatural { context.fill(Path(row), with: .color(.black.opacity(0.19))) }
            context.stroke(Path { line in
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: layout.size.width, y: y))
            }, with: .color(StudioTheme.secondary.opacity(pitch % 12 == 0 ? 0.33 : 0.10)), lineWidth: 0.7)
            if (isNatural || pitchSelected), layout.row >= 11 {
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
            let isSnap = step.isMultiple(of: snap.rawValue)
            let opacity: Double = isBar ? 0.36 : isBeat ? 0.17 : isSnap ? 0.10 : 0.035
            context.stroke(Path { line in
                line.move(to: CGPoint(x: x, y: layout.header))
                line.addLine(to: CGPoint(x: x, y: layout.size.height))
            }, with: .color(StudioTheme.secondary.opacity(opacity)), lineWidth: isBar ? 1 : 0.6)

            if isBar, step < MelodyProject.steps {
                context.draw(
                    Text("\(step / MelodyProject.stepsPerBar + 1)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(StudioTheme.ink.opacity(0.84)),
                    at: CGPoint(x: x + 8, y: layout.header / 2), anchor: .leading
                )
            }
        }
    }

    private func drawNotes(_ context: GraphicsContext, layout: RollLayout) {
        for note in model.activeTrack?.notes ?? [] {
            let visible = drag?.original.id == note.id ? (drag?.candidate ?? note) : note
            drawNote(visible, context: context, layout: layout, selected: note.id == model.selectedID)
        }
        if let drawing { drawNote(drawing, context: context, layout: layout, selected: true, ghost: true) }
    }

    private func drawNote(_ note: MelodyNote, context: GraphicsContext, layout: RollLayout, selected: Bool, ghost: Bool = false) {
        let rect = layout.rect(note)
        let outline = Path(roundedRect: rect, cornerRadius: 3)
        let color = selected ? Self.accent : StudioTheme.secondary
        context.fill(outline, with: .color(color.opacity(ghost ? 0.45 : selected ? 1 : 0.78)))
        if selected { context.stroke(outline, with: .color(.white.opacity(0.85)), lineWidth: 1.3) }
        if rect.width > 22, rect.height >= 10 {
            let fontSize = min(12, rect.height - 2)
            let lyric = note.lyric.isEmpty ? "ら" : note.lyric
            let maxCharacters = max(1, Int((rect.width - 12) / fontSize))
            context.draw(
                Text(String(lyric.prefix(maxCharacters)))
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(.black),
                at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading
            )
        }
        if selected, rect.width > 28 {
            let gripHeight = min(8, rect.height - 4)
            if gripHeight > 0 {
                let grip = CGRect(x: rect.maxX - 6, y: rect.midY - gripHeight / 2, width: 2.5, height: gripHeight)
                context.fill(Path(roundedRect: grip, cornerRadius: 1), with: .color(.black.opacity(0.55)))
            }
        }
    }

    private func drawCursor(_ context: GraphicsContext, layout: RollLayout, step: Double, color: Color, width: CGFloat) {
        let x = min(layout.size.width - 1, layout.keys + CGFloat(step) * layout.step)
        context.stroke(Path { line in
            line.move(to: CGPoint(x: x, y: layout.header))
            line.addLine(to: CGPoint(x: x, y: layout.size.height))
        }, with: .color(color), lineWidth: width)
        context.fill(Path { marker in
            marker.move(to: CGPoint(x: x - 5, y: layout.header - 6))
            marker.addLine(to: CGPoint(x: x + 5, y: layout.header - 6))
            marker.addLine(to: CGPoint(x: x, y: layout.header))
            marker.closeSubpath()
        }, with: .color(color))
    }

    private func hit(_ point: CGPoint, layout: RollLayout) -> MelodyNote? {
        model.activeTrack?.notes.first { layout.rect($0).insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func gridStep(_ x: CGFloat, layout: RollLayout) -> Int {
        max(0, min(MelodyProject.steps - snap.rawValue, snap.floor((x - layout.keys) / layout.step)))
    }

    private func notePitch(_ y: CGFloat, layout: RollLayout) -> Int? {
        guard y >= layout.header, y < layout.size.height else { return nil }
        let pitch = MelodyProject.pitches.upperBound - Int((y - layout.header) / layout.row)
        return MelodyProject.pitches.contains(pitch) ? pitch : nil
    }

    private func positionCursor(_ step: Int) {
        model.seek(to: step)
        if showsEntryCursor { model.moveEntryCursor(to: step) }
    }

    private func tap(_ point: CGPoint, layout: RollLayout) {
        guard model.activeTrack?.id == trackID, drag == nil, drawing == nil,
              point.x >= 0, point.x < layout.size.width else { return }
        if point.y >= 0, point.y < layout.header, point.x >= layout.keys {
            positionCursor(gridStep(point.x, layout: layout))
            return
        }
        guard let pitch = notePitch(point.y, layout: layout) else { return }
        if point.x < layout.keys {
            model.audition(pitch: pitch)
        } else if let note = hit(point, layout: layout) {
            model.select(note)
        } else if tool == .draw {
            model.add(start: gridStep(point.x, layout: layout), pitch: pitch)
        } else {
            model.selectedID = nil
        }
    }

    private func dragChanged(_ value: DragGesture.Value, layout: RollLayout) {
        guard model.activeTrack?.id == trackID else { return }
        let origin = value.startLocation
        if origin.y < layout.header, origin.x >= layout.keys {
            let step = gridStep(value.location.x, layout: layout)
            if model.transportStep != step || (showsEntryCursor && model.entryStep != step) {
                positionCursor(step)
            }
            return
        }
        guard origin.x >= layout.keys, let pitch = notePitch(origin.y, layout: layout) else { return }
        if drag == nil, let note = hit(origin, layout: layout) {
            let rect = layout.rect(note)
            let resizing = origin.x >= rect.maxX - min(14, rect.width / 3)
            model.selectedID = note.id
            drag = NoteDrag(original: note, candidate: note, resizing: resizing)
        }
        if var current = drag {
            let delta = value.translation.width / layout.step
            var candidate = current.original
            if current.resizing {
                if abs(delta) >= CGFloat(snap.rawValue) / 2 {
                    let firstEnd = snap.floor(CGFloat(candidate.start)) + snap.rawValue
                    let end = max(firstEnd, min(MelodyProject.steps, snap.nearest(CGFloat(candidate.end) + delta)))
                    candidate.length = end - candidate.start
                }
            } else {
                if abs(delta) >= CGFloat(snap.rawValue) / 2 {
                    let start = snap.nearest(CGFloat(candidate.start) + delta)
                    let lastStart = snap.floor(CGFloat(MelodyProject.steps - candidate.length))
                    candidate.start = max(0, min(lastStart, start))
                }
                let vertical = Int((value.translation.height / layout.row).rounded())
                candidate.pitch = max(MelodyProject.pitches.lowerBound, min(MelodyProject.pitches.upperBound, candidate.pitch - vertical))
            }
            if model.activeTrack?.canPlace(candidate) == true {
                current.candidate = candidate
                drag = current
            }
        } else if tool == .draw {
            let from = gridStep(origin.x, layout: layout)
            let to = gridStep(value.location.x, layout: layout)
            drawing = model.activeTrack?.newNote(at: min(from, to), pitch: pitch, length: abs(from - to) + snap.rawValue)
        }
    }

    private func commitDrag() {
        defer {
            drag = nil
            drawing = nil
        }
        guard model.activeTrack?.id == trackID else { return }
        if let drag, drag.candidate != drag.original, model.place(drag.candidate) {
            if drag.candidate.pitch != drag.original.pitch { model.audition(pitch: drag.candidate.pitch) }
        } else if let drawing, model.place(drawing) {
            model.select(drawing)
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