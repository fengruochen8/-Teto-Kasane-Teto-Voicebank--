import SwiftUI

@MainActor
struct TrackPanel: View {
    @ObservedObject var model: StudioModel
    var compact = false
    @State private var editingTrack: MelodyTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("音轨").font(.subheadline.weight(.semibold)).foregroundStyle(StudioTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("新增音轨", systemImage: "plus") { model.addTrack() }
                    .labelStyle(.iconOnly).buttonStyle(StudioButtonStyle())
                    .disabled(model.project.tracks.count >= MelodyProject.maxTracks)
            }

            ScrollViewReader { scroll in
                if compact {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(model.project.tracks) { track in row(track).frame(width: 218).id(track.id) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.activeTrackID) { _, id in if let id { scroll.scrollTo(id, anchor: .center) } }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 7) { ForEach(model.project.tracks) { track in row(track).id(track.id) } }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.activeTrackID) { _, id in if let id { scroll.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .padding(9)
        .studioPanel(radius: 14)
        .sheet(item: $editingTrack) { track in
            TrackSettingsSheet(track: track, trackCount: model.project.tracks.count) { name, volume in
                model.updateTrack(track.id, name: name, volume: volume)
            } onDuplicate: {
                model.duplicateTrack(track.id)
            } onMove: { offset in
                model.moveTrack(track.id, by: offset)
            } onDelete: {
                model.removeTrack(track.id)
            }
        }
    }

    private func row(_ track: MelodyTrack) -> some View {
        let selected = model.activeTrack?.id == track.id
        return HStack(spacing: 4) {
            Button { model.selectTrack(track.id) } label: {
                HStack(spacing: 7) {
                    Capsule().fill(selected ? StudioTheme.accent : StudioTheme.secondary.opacity(0.55))
                        .frame(width: 3, height: 25).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name).font(.subheadline.weight(.semibold)).foregroundStyle(StudioTheme.ink).lineLimit(1)
                        Text("\(track.notes.count)个音符 · \(Int((track.volume * 100).rounded()))%")
                            .font(.caption).foregroundStyle(StudioTheme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("\(track.name)音轨，\(track.notes.count)个音符，音量\(Int((track.volume * 100).rounded()))%")

            trackMenu(track)
            toggle("M", name: track.isMuted ? "取消静音\(track.name)" : "静音\(track.name)", active: track.isMuted, color: StudioTheme.accent) { model.toggleMute(track.id) }
            toggle("S", name: track.isSolo ? "取消独奏\(track.name)" : "独奏\(track.name)", active: track.isSolo, color: StudioTheme.secondary) { model.toggleSolo(track.id) }
        }
        .padding(5)
        .background(selected ? StudioTheme.raised : StudioTheme.background.opacity(0.52), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? StudioTheme.accent.opacity(0.7) : StudioTheme.border.opacity(0.65))
                .allowsHitTesting(false)
        }
    }

    private func trackMenu(_ track: MelodyTrack) -> some View {
        Menu {
            Button("编辑音轨", systemImage: "slider.horizontal.3") { editingTrack = track }
            Button("复制音轨", systemImage: "plus.square.on.square") { model.duplicateTrack(track.id) }
                .disabled(model.project.tracks.count >= MelodyProject.maxTracks)
            Divider()
            Button("上移", systemImage: "arrow.up") { model.moveTrack(track.id, by: -1) }
                .disabled(model.project.tracks.first?.id == track.id)
            Button("下移", systemImage: "arrow.down") { model.moveTrack(track.id, by: 1) }
                .disabled(model.project.tracks.last?.id == track.id)
        } label: {
            Image(systemName: "ellipsis").frame(width: 30, height: 36).foregroundStyle(StudioTheme.muted).contentShape(Rectangle())
        }
        .accessibilityLabel("\(track.name)音轨选项")
    }

    private func toggle(_ label: String, name: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(active ? StudioTheme.background : StudioTheme.muted)
                .frame(width: 30, height: 36).background(active ? color : StudioTheme.background, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct TrackSettingsSheet: View {
    let track: MelodyTrack
    let trackCount: Int
    let onSave: (String, Double) -> Void
    let onDuplicate: () -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var volume: Double
    @State private var confirmsDeletion = false

    init(track: MelodyTrack, trackCount: Int, onSave: @escaping (String, Double) -> Void, onDuplicate: @escaping () -> Void, onMove: @escaping (Int) -> Void, onDelete: @escaping () -> Void) {
        self.track = track
        self.trackCount = trackCount
        self.onSave = onSave
        self.onDuplicate = onDuplicate
        self.onMove = onMove
        self.onDelete = onDelete
        _name = State(initialValue: track.name)
        _volume = State(initialValue: track.volume)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("音轨") {
                    TextField("音轨名称", text: $name).textInputAutocapitalization(.never).accessibilityLabel("音轨名称")
                    HStack {
                        Text("音量")
                        Slider(value: $volume, in: 0...2, step: 0.01).accessibilityLabel("音量")
                        Text("\(Int((volume * 100).rounded()))%").monospacedDigit().foregroundStyle(StudioTheme.muted).frame(width: 48, alignment: .trailing)
                    }
                }
                Section("排列") {
                    Button("复制音轨", systemImage: "plus.square.on.square", action: onDuplicate).disabled(trackCount >= MelodyProject.maxTracks)
                    Button("上移", systemImage: "arrow.up") { onMove(-1) }
                    Button("下移", systemImage: "arrow.down") { onMove(1) }
                }
                Section {
                    Button("删除音轨", systemImage: "trash", role: .destructive) { confirmsDeletion = true }.disabled(trackCount <= 1)
                }
            }
            .scrollContentBackground(.hidden).background(StudioTheme.backdrop.ignoresSafeArea())
            .navigationTitle("音轨设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), volume); dismiss() }
                        .disabled(!MelodyTrack.isValidName(name.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            .alert("删除「\(track.name)」？", isPresented: $confirmsDeletion) {
                Button("删除", role: .destructive) { onDelete(); dismiss() }
                Button("取消", role: .cancel) {}
            } message: { Text("音轨中的音符和歌词将一并删除。") }
        }
        .tint(StudioTheme.accent)
    }
}
