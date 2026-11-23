import SwiftUI

@MainActor
struct TrackPanel: View {
    @ObservedObject var model: StudioModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("音轨")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("新增音轨", systemImage: "plus") { model.addTrack() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(StudioButtonStyle())
                    .disabled(model.project.tracks.count >= MelodyProject.maxTracks)
            }

            ScrollViewReader { scroll in
                if compact {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(model.project.tracks) { track in
                                row(track)
                                    .frame(width: 188)
                                    .id(track.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.activeTrackID) { _, id in
                        if let id { scroll.scrollTo(id, anchor: .center) }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(model.project.tracks) { track in
                                row(track).id(track.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.activeTrackID) { _, id in
                        if let id { scroll.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .padding(9)
        .studioPanel(radius: 14)
    }

    private func row(_ track: MelodyTrack) -> some View {
        let selected = model.activeTrack?.id == track.id
        HStack(spacing: 4) {
            Button {
                model.selectTrack(track.id)
            } label: {
                HStack(spacing: 7) {
                    Capsule()
                        .fill(selected ? StudioTheme.accent : StudioTheme.secondary.opacity(0.55))
                        .frame(width: 3, height: 25)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.ink)
                            .lineLimit(1)
                        Text("\(track.notes.count)个音符")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("\(track.name)音轨，\(track.notes.count)个音符")

            toggle(
                "M", name: track.isMuted ? "取消静音\(track.name)" : "静音\(track.name)",
                active: track.isMuted, color: StudioTheme.accent
            ) { model.toggleMute(track.id) }
            toggle(
                "S", name: track.isSolo ? "取消独奏\(track.name)" : "独奏\(track.name)",
                active: track.isSolo, color: StudioTheme.secondary
            ) { model.toggleSolo(track.id) }
        }
        .padding(5)
        .background(selected ? StudioTheme.raised : StudioTheme.background.opacity(0.52),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? StudioTheme.accent.opacity(0.7) : StudioTheme.border.opacity(0.65))
                .allowsHitTesting(false)
        }
    }

    private func toggle(_ label: String, name: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(active ? StudioTheme.background : StudioTheme.muted)
                .frame(width: 32, height: 36)
                .background(active ? color : StudioTheme.background, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}