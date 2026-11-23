import SwiftUI

enum PianoRollTool: Hashable {
    case select
    case draw
    case box
    case pan
}

enum GridSnap: Int, Hashable, CaseIterable {
    case sixteenth = 120
    case eighth = 240
    case quarter = 480

    var label: String { "1/\(MelodyProject.stepsPerBar / rawValue)" }

    func floor(_ tick: CGFloat) -> Int {
        Int((tick / CGFloat(rawValue)).rounded(.down)) * rawValue
    }

    func nearest(_ tick: CGFloat) -> Int {
        Int((tick / CGFloat(rawValue)).rounded()) * rawValue
    }
}

@MainActor
struct PianoRoll: View {
    @ObservedObject var model: StudioModel
    let trackID: UUID
    let showsEntryCursor: Bool
    let tool: PianoRollTool
    let snap: GridSnap

    @State private var origin = 0.0
    @State private var barsVisible = 4.0
    @State private var topPitch = 78
    @State private var panOrigin: PanOrigin?
    @State private var zoomOrigin: Double?
    @State private var zoomAnchor: Double?
    @State private var drag: NoteDrag?
    @State private var drawing: MelodyNote?
    @State private var box: CGRect?
    @State private var loopDraft: MeasureLoop?

    static let accent = StudioTheme.accent
    private let naturalKeys: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
    private let rows = 24
    private var maximumOrigin: Double { max(0, Double(model.project.steps) - visibleTicks) }
    private var visibleTicks: Double { min(Double(model.project.steps), barsVisible * Double(MelodyProject.stepsPerBar)) }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let layout = RollLayout(size: geometry.size, origin: origin, ticksVisible: visibleTicks,
                                        topPitch: topPitch, rows: rows)
                let notes = model.activeTrack?.notes ?? []
                ZStack {
                    Canvas { context, _ in
                        drawGrid(context, layout: layout)
                        var score = context
                        score.clip(to: Path(layout.scoreBounds))
                        drawNotes(score, layout: layout, notes: notes)
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isPlaying)) { _ in
                        Canvas { context, _ in
                            drawPlayheads(context, layout: layout, playback: model.playbackPosition)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .background(StudioTheme.roll)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(StudioTheme.border)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { changeDrag($0, layout: layout) }
                        .onEnded { _ in finishDrag(layout: layout) }
                        .exclusively(before: SpatialTapGesture().onEnded { tap($0.location, layout: layout) })
                )
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { changeZoom(Double($0.magnification)) }
                    .onEnded { _ in
                        zoomOrigin = nil
                        zoomAnchor = nil
                    })
                .accessibilityLabel("旋律网格")
                .accessibilityHint("点时间尺定位，拖动时间尺设置循环区间，双指缩放时间轴。")
            }
            navigationStrip
        }
        .onAppear(perform: focusTrack)
        .onChange(of: model.project.barCount) { _, _ in setOrigin(origin) }
        .onChange(of: tool) { _, _ in clearGesture() }
    }

    private var navigationStrip: some View {
        HStack(spacing: 7) {
            Button("缩小时间轴", systemImage: "minus.magnifyingglass") { setZoom(barsVisible * 2) }
                .disabled(barsVisible >= min(32, Double(model.project.barCount)))
            Button("放大时间轴", systemImage: "plus.magnifyingglass") { setZoom(barsVisible / 2) }
                .disabled(barsVisible <= 0.5)
            if maximumOrigin > 0 {
                Slider(value: Binding(get: { origin }, set: setOrigin), in: 0...maximumOrigin)
                    .accessibilityLabel("横向移动时间轴")
            }
            Text("第\(Int(origin) / MelodyProject.stepsPerBar + 1) / \(model.project.barCount)小节")
                .font(.caption.monospacedDigit())
                .foregroundStyle(StudioTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 2)
            Button("音高视图下降八度", systemImage: "arrow.down") { setTopPitch(topPitch - 12) }
                .disabled(topPitch == rows - 1)
            Button("音高视图上升八度", systemImage: "arrow.up") { setTopPitch(topPitch + 12) }
                .disabled(topPitch == MelodyProject.pitches.upperBound)
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .font(.subheadline)
        .padding(.horizontal, 6)
        .frame(minHeight: 29)
    }

    private func focusTrack() {
        setOrigin(Double(model.entryStep) - visibleTicks / 4)
        guard let first = model.activeTrack?.notes.min(by: { $0.start < $1.start }) else { return }
        if first.pitch < topPitch - rows + 1 || first.pitch > topPitch { setTopPitch(first.pitch + rows / 2) }
    }

    private func setOrigin(_ value: Double) {
        origin = max(0, min(maximumOrigin, value))
    }

    private func setTopPitch(_ pitch: Int) {
        topPitch = max(rows - 1, min(MelodyProject.pitches.upperBound, pitch))
    }

    private func setZoom(_ value: Double, anchor: Double? = nil) {
        let focus = anchor ?? origin + visibleTicks / 2
        barsVisible = max(0.5, min(min(32, Double(model.project.barCount)), value))
        setOrigin(focus - visibleTicks / 2)
    }

    private func changeZoom(_ amount: Double) {
        guard amount > 0 else { return }
        if zoomOrigin == nil {
            clearGesture()
            zoomOrigin = min(barsVisible, Double(model.project.barCount))
            zoomAnchor = origin + visibleTicks / 2
        }
        if let zoomOrigin { setZoom(zoomOrigin / amount, anchor: zoomAnchor) }
    }

    private func drawGrid(_ context: GraphicsContext, layout: RollLayout) {
        context.fill(Path(CGRect(x: 0, y: 0, width: layout.size.width, height: layout.header)), with: .color(StudioTheme.raised))
        if let loop = loopDraft ?? model.project.loopRegion {
            let lower = max(layout.keys, layout.x(loop.ticks.lowerBound))
            let upper = min(layout.size.width, layout.x(loop.ticks.upperBound))
            if lower < upper {
                let band = CGRect(x: lower, y: 0, width: upper - lower, height: layout.header)
                context.fill(Path(band), with: .color(StudioTheme.accent.opacity(model.loops || loopDraft != nil ? 0.48 : 0.22)))
            }
        }
        let activePitch = drag?.candidate.pitch ?? drawing?.pitch ?? model.selected?.pitch
        for pitch in (layout.topPitch - rows + 1)...layout.topPitch {
            let y = layout.rowTop(pitch)
            let natural = naturalKeys.contains(pitch % 12)
            let active = pitch == activePitch
            let key = CGRect(x: 0, y: y, width: layout.keys, height: layout.row)
            let row = CGRect(x: layout.keys, y: y, width: layout.scoreBounds.width, height: layout.row)
            context.fill(Path(key), with: .color(active ? Self.accent : natural ? StudioTheme.keyWhite : StudioTheme.keyBlack))
            if !natural { context.fill(Path(row), with: .color(.black.opacity(0.19))) }
            context.stroke(Path { line in
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: layout.size.width, y: y))
            }, with: .color(StudioTheme.secondary.opacity(pitch % 12 == 0 ? 0.33 : 0.10)), lineWidth: 0.7)
            if (natural || active), layout.row >= 10 {
                context.draw(Text(MelodyProject.noteName(pitch)).font(.system(size: min(11, layout.row * 0.7), design: .monospaced))
                    .foregroundColor(.black.opacity(0.8)), at: CGPoint(x: layout.keys / 2, y: y + layout.row / 2))
            }
        }
        let subdivision = layout.tick * CGFloat(snap.rawValue) >= 7 ? snap.rawValue : MelodyProject.stepsPerBeat
        let spacing = layout.tick * CGFloat(subdivision) >= 7 ? subdivision : MelodyProject.stepsPerBar
        let first = Int((layout.origin / Double(spacing)).rounded(.up)) * spacing
        let end = min(model.project.steps, Int(layout.origin + layout.ticksVisible))
        if first <= end {
            for tick in stride(from: first, through: end, by: spacing) {
                let x = layout.x(tick)
                let isBar = tick.isMultiple(of: MelodyProject.stepsPerBar)
                let isBeat = tick.isMultiple(of: MelodyProject.stepsPerBeat)
                context.stroke(Path { line in
                    line.move(to: CGPoint(x: x, y: layout.header))
                    line.addLine(to: CGPoint(x: x, y: layout.size.height))
                }, with: .color(StudioTheme.secondary.opacity(isBar ? 0.36 : isBeat ? 0.17 : 0.08)), lineWidth: isBar ? 1 : 0.6)
                if isBar, tick < model.project.steps {
                    context.draw(Text("\(tick / MelodyProject.stepsPerBar + 1)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(StudioTheme.ink),
                        at: CGPoint(x: x + 6, y: layout.header / 2), anchor: .leading)
                }
            }
        }
    }

    private func drawNotes(_ context: GraphicsContext, layout: RollLayout, notes: [MelodyNote]) {
        for note in notes where layout.includes(note) || note.id == drag?.original.id {
            let visible = drag?.original.id == note.id ? (drag?.candidate ?? note) : note
            drawNote(visible, context: context, layout: layout, selected: model.selectedIDs.contains(note.id))
        }
        if let drawing { drawNote(drawing, context: context, layout: layout, selected: true, ghost: true) }
        if let box {
            context.fill(Path(box), with: .color(StudioTheme.accent.opacity(0.19)))
            context.stroke(Path(box), with: .color(StudioTheme.accent.opacity(0.8)), lineWidth: 1)
        }
    }

    private func drawNote(_ note: MelodyNote, context: GraphicsContext, layout: RollLayout, selected: Bool, ghost: Bool = false) {
        let rect = layout.rect(note)
        let outline = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(outline, with: .color((selected ? Self.accent : StudioTheme.secondary).opacity(ghost ? 0.45 : selected ? 1 : 0.78)))
        if selected { context.stroke(outline, with: .color(.white.opacity(0.85)), lineWidth: 1.3) }
        let visibleLeft = max(layout.keys, rect.minX)
        if rect.maxX - visibleLeft > 20, rect.height >= 10 {
            let fontSize = min(12, rect.height - 2)
            let lyric = note.expression.slur ? "‿" : note.lyric.isEmpty ? "ら" : note.lyric
            let count = max(1, Int((rect.maxX - visibleLeft - 9) / fontSize))
            context.draw(Text(String(lyric.prefix(count))).font(.system(size: fontSize, weight: .semibold)).foregroundColor(.black),
                         at: CGPoint(x: visibleLeft + 4, y: rect.midY), anchor: .leading)
        }
        if selected, rect.width > 28, rect.height > 5 {
            let height = min(8, rect.height - 4)
            let grip = CGRect(x: rect.maxX - 6, y: rect.midY - height / 2, width: 2.5, height: height)
            context.fill(Path(roundedRect: grip, cornerRadius: 1), with: .color(.black.opacity(0.55)))
        }
    }

    private func drawPlayheads(_ context: GraphicsContext, layout: RollLayout, playback: Double?) {
        if let playback {
            drawCursor(context, layout: layout, tick: playback, color: StudioTheme.playhead, width: 2)
        } else if showsEntryCursor {
            if model.entryStep != model.transportStep {
                drawCursor(context, layout: layout, tick: Double(model.transportStep), color: .white.opacity(0.48), width: 1)
            }
            drawCursor(context, layout: layout, tick: Double(model.entryStep), color: Self.accent, width: 1.5)
        } else {
            drawCursor(context, layout: layout, tick: Double(model.transportStep), color: StudioTheme.playhead.opacity(0.72), width: 1.5)
        }
    }

    private func drawCursor(_ context: GraphicsContext, layout: RollLayout, tick: Double, color: Color, width: CGFloat) {
        guard tick >= layout.origin, tick <= layout.origin + layout.ticksVisible else { return }
        let x = min(layout.size.width - 1, layout.keys + CGFloat(tick - layout.origin) * layout.tick)
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
        model.activeTrack?.notes.first { layout.includes($0) && layout.rect($0).insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func gridTick(_ x: CGFloat, layout: RollLayout) -> Int {
        max(0, min(model.project.steps - 1, snap.floor(layout.rawTick(x))))
    }

    private func tap(_ point: CGPoint, layout: RollLayout) {
        guard model.activeTrack?.id == trackID, zoomOrigin == nil else { return }
        if point.y < layout.header, point.x >= layout.keys {
            let step = gridTick(point.x, layout: layout)
            model.seek(to: step)
            model.moveEntryCursor(to: step)
            return
        }
        guard let pitch = layout.pitch(point.y) else { return }
        if point.x < layout.keys { model.audition(pitch: pitch) }
        else if let note = hit(point, layout: layout) { model.select(note) }
        else if tool == .draw { model.add(start: gridTick(point.x, layout: layout), pitch: pitch) }
        else if tool != .pan { model.clearSelection() }
    }

    private func changeDrag(_ value: DragGesture.Value, layout: RollLayout) {
        guard model.activeTrack?.id == trackID, zoomOrigin == nil else { return }
        let start = value.startLocation
        if start.y < layout.header, start.x >= layout.keys {
            let measure = MelodyProject.stepsPerBar
            let first = gridTick(start.x, layout: layout) / measure
            let last = gridTick(value.location.x, layout: layout) / measure
            loopDraft = MeasureLoop(firstBar: min(first, last), endBar: max(first, last) + 1)
            return
        }
        if tool == .pan || start.x < layout.keys {
            if panOrigin == nil { panOrigin = PanOrigin(tick: origin, pitch: topPitch) }
            if let panOrigin {
                setOrigin(panOrigin.tick - Double(value.translation.width / layout.tick))
                setTopPitch(panOrigin.pitch + Int((value.translation.height / layout.row).rounded()))
            }
            return
        }
        if tool == .box {
            let end = value.location
            box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            return
        }
        if drag == nil, let note = hit(start, layout: layout) {
            let rect = layout.rect(note)
            model.setSelection([note.id], primary: note.id)
            drag = NoteDrag(original: note, candidate: note, resizing: start.x >= rect.maxX - min(14, rect.width / 3))
        }
        if var current = drag {
            let horizontal = value.translation.width / layout.tick
            var candidate = current.original
            if abs(horizontal) >= CGFloat(snap.rawValue) / 2 {
                if current.resizing {
                    let end = max(candidate.start + 1, min(model.project.steps, snap.nearest(CGFloat(candidate.end) + horizontal)))
                    candidate.length = end - candidate.start
                } else {
                    let newStart = snap.nearest(CGFloat(candidate.start) + horizontal)
                    candidate.start = max(0, min(model.project.steps - candidate.length, newStart))
                }
            }
            if !current.resizing {
                let vertical = Int((value.translation.height / layout.row).rounded())
                candidate.pitch = min(127, max(0, candidate.pitch - vertical))
            }
            if model.activeTrack?.canPlace(candidate, limit: model.project.steps) == true {
                current.candidate = candidate
                drag = current
            }
        } else if tool == .draw, let pitch = layout.pitch(start.y) {
            let from = gridTick(start.x, layout: layout)
            let to = gridTick(value.location.x, layout: layout)
            drawing = model.activeTrack?.newNote(at: min(from, to), pitch: pitch,
                                                 length: abs(from - to) + snap.rawValue, limit: model.project.steps)
        }
    }

    private func finishDrag(layout: RollLayout) {
        defer { clearGesture() }
        guard model.activeTrack?.id == trackID, zoomOrigin == nil else { return }
        if let loopDraft {
            model.setLoop(firstBar: loopDraft.firstBar, endBar: loopDraft.endBar)
            model.moveEntryCursor(to: loopDraft.ticks.lowerBound)
        } else if let box, let track = model.activeTrack {
            let notes = track.notes.filter { layout.includes($0) && layout.rect($0).intersects(box) }
            model.setSelection(Set(notes.map(\.id)))
        } else if let drag, drag.candidate != drag.original, model.place(drag.candidate) {
            if drag.candidate.pitch != drag.original.pitch { model.audition(pitch: drag.candidate.pitch) }
        } else if let drawing, model.place(drawing) {
            model.select(drawing)
        }
    }

    private func clearGesture() {
        panOrigin = nil
        drag = nil
        drawing = nil
        box = nil
        loopDraft = nil
    }
}

private struct PanOrigin {
    let tick: Double
    let pitch: Int
}

private struct NoteDrag {
    let original: MelodyNote
    var candidate: MelodyNote
    let resizing: Bool
}

private struct RollLayout {
    let size: CGSize
    let origin: Double
    let ticksVisible: Double
    let topPitch: Int
    let rows: Int
    let keys: CGFloat = 46
    let header: CGFloat = 26

    var scoreBounds: CGRect { CGRect(x: keys, y: header, width: max(1, size.width - keys), height: max(1, size.height - header)) }
    var row: CGFloat { max(1, scoreBounds.height / CGFloat(rows)) }
    var tick: CGFloat { scoreBounds.width / CGFloat(ticksVisible) }

    func x(_ tick: Int) -> CGFloat { keys + CGFloat(Double(tick) - origin) * self.tick }
    func rawTick(_ x: CGFloat) -> CGFloat { CGFloat(origin) + (x - keys) / tick }
    func rowTop(_ pitch: Int) -> CGFloat { header + CGFloat(topPitch - pitch) * row }

    func pitch(_ y: CGFloat) -> Int? {
        guard y >= header, y < size.height else { return nil }
        return topPitch - min(rows - 1, Int((y - header) / row))
    }

    func includes(_ note: MelodyNote) -> Bool {
        Double(note.end) > origin && Double(note.start) < origin + ticksVisible &&
            note.pitch <= topPitch && note.pitch > topPitch - rows
    }

    func rect(_ note: MelodyNote) -> CGRect {
        CGRect(x: x(note.start) + 1, y: rowTop(note.pitch) + 1,
               width: max(2, CGFloat(note.length) * tick - 2), height: max(2, row - 2))
    }
}
