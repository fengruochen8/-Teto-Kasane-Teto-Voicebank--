import SwiftUI

@MainActor
struct BatchLyricsSheet: View {
    private enum FillScope: String, CaseIterable, Identifiable {
        case fromCurrent
        case wholeTrack

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fromCurrent: return "从当前音符开始"
            case .wholeTrack: return "从音轨开头"
            }
        }
    }

    private struct Assignment: Identifiable {
        let note: MelodyNote
        let lyric: String

        var id: UUID { note.id }
    }

    let track: MelodyTrack
    let selectedID: UUID?
    let entryStep: Int
    let availableSamples: Set<String>?
    let onApply: ([UUID: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceText = ""
    @State private var reading = ""
    @State private var syllables: [String] = []
    @State private var scope: FillScope = .wholeTrack
    @State private var conversionError: String?
    @State private var splitError: String?
    @State private var isConverting = false

    private var orderedNotes: [MelodyNote] {
        track.notes.sorted { left, right in
            left.start == right.start ? left.pitch < right.pitch : left.start < right.start
        }
    }

    private var startIndex: Int {
        guard scope == .fromCurrent else { return 0 }
        if let selectedID, let index = orderedNotes.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return orderedNotes.firstIndex(where: { $0.start >= entryStep }) ?? orderedNotes.count
    }

    private var targetNotes: [MelodyNote] {
        Array(orderedNotes.dropFirst(startIndex))
    }

    private var assignments: [Assignment] {
        zip(targetNotes, syllables).map { Assignment(note: $0.0, lyric: $0.1) }
    }

    private var hasOverflow: Bool {
        syllables.count > targetNotes.count
    }

    private var canApply: Bool {
        !isConverting && !syllables.isEmpty && !hasOverflow && splitError == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    sourceEditor
                    readingEditor
                    destinationPicker
                    preview
                }
                .padding(18)
            }
            .background(StudioTheme.backdrop.ignoresSafeArea())
            .navigationTitle("批量歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("写入\(assignments.count)个音符") { apply() }
                        .disabled(!canApply)
                }
            }
        }
        .tint(StudioTheme.accent)
        .onChange(of: sourceText) { _, _ in
            conversionError = nil
            reading = ""
            syllables = []
            splitError = nil
        }
        .onChange(of: reading) { _, _ in updateSyllables() }
        .onAppear {
            if selectedID != nil { scope = .fromCurrent }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(track.name)
                .font(.headline)
                .foregroundStyle(StudioTheme.ink)
            Text("输入日语句子后会转换为平假名，再按发音顺序填入音符。写入前可直接修正假名。")
                .font(.subheadline)
                .foregroundStyle(StudioTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .studioPanel()
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日语歌词")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.ink)
            TextEditor(text: $sourceText)
                .scrollContentBackground(.hidden)
                .foregroundStyle(StudioTheme.ink)
                .frame(minHeight: 90)
                .padding(8)
                .background(StudioTheme.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("日语歌词")
            Button {
                convertSource()
            } label: {
                if isConverting {
                    ProgressView().tint(StudioTheme.background)
                } else {
                    Label("转换为假名", systemImage: "character.book.closed")
                }
            }
            .buttonStyle(StudioButtonStyle(prominent: true))
            .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConverting)
            if let conversionError {
                errorText(conversionError)
            }
        }
    }

    private var readingEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("假名与拆分")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.ink)
            TextEditor(text: $reading)
                .scrollContentBackground(.hidden)
                .foregroundStyle(StudioTheme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 80)
                .padding(8)
                .background(StudioTheme.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("可编辑的日语假名")
                .disabled(isConverting)
            if reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("先转换日语歌词，或直接输入平假名。")
                    .font(.footnote)
                    .foregroundStyle(StudioTheme.muted)
            } else if !syllables.isEmpty {
                Text(syllables.joined(separator: " · "))
                    .font(.subheadline.monospaced())
                    .foregroundStyle(StudioTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("拆分结果，\(syllables.joined(separator: "、"))")
            }
            if let splitError {
                errorText(splitError)
            }
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("写入范围")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.ink)
            Picker("写入范围", selection: $scope) {
                ForEach(FillScope.allCases) { item in
                    Text(item == .fromCurrent && selectedID == nil ? "从录入光标" : item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Text(destinationDescription)
                .font(.footnote)
                .foregroundStyle(StudioTheme.muted)
        }
    }

    private var destinationDescription: String {
        guard !targetNotes.isEmpty else {
            return scope == .fromCurrent ? "当前光标之后没有可写入的音符。" : "当前音轨没有音符。"
        }
        return "将从第\(startIndex + 1)个音符开始，最多写入\(targetNotes.count)个音符。"
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("写入预览")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioTheme.ink)
                Spacer()
                Text("\(assignments.count) / \(syllables.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(hasOverflow ? StudioTheme.accent : StudioTheme.muted)
            }
            if hasOverflow {
                errorText("还有\(syllables.count - targetNotes.count)个发音没有对应音符，请增加音符或缩短歌词后再写入。")
            }
            if assignments.isEmpty && splitError == nil && !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("未找到可识别的日语发音。")
                    .font(.footnote)
                    .foregroundStyle(StudioTheme.muted)
            }
            ForEach(assignments) { assignment in
                HStack(spacing: 10) {
                    Text("第\(assignment.note.start / MelodyProject.stepsPerBar + 1)小节")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                        .frame(width: 42, alignment: .leading)
                    Text(MelodyProject.noteName(assignment.note.pitch))
                        .font(.caption.monospaced())
                        .foregroundStyle(StudioTheme.muted)
                        .frame(width: 30, alignment: .leading)
                    Text(assignment.note.lyric)
                        .font(.body)
                        .foregroundStyle(StudioTheme.muted)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.muted)
                    Text(assignment.lyric)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(StudioTheme.ink)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            if syllables.count < targetNotes.count && !syllables.isEmpty {
                Text("将保留后面\(targetNotes.count - syllables.count)个音符的歌词。")
                    .font(.footnote)
                    .foregroundStyle(StudioTheme.muted)
            }
        }
        .padding(14)
        .studioPanel()
    }

    private func errorText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(StudioTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func convertSource() {
        let input = sourceText
        conversionError = nil
        isConverting = true
        Task {
            defer { isConverting = false }
            do {
                let converted = try await Task.detached(priority: .userInitiated) {
                    try JapaneseLyrics.reading(for: input)
                }.value
                guard sourceText == input else { return }
                reading = converted
            } catch {
                guard sourceText == input else { return }
                conversionError = error.localizedDescription
            }
        }
    }

    private func updateSyllables() {
        do {
            syllables = try JapaneseLyrics.syllables(in: reading, availableSamples: availableSamples)
            splitError = nil
        } catch {
            syllables = []
            splitError = error.localizedDescription
        }
    }

    private func apply() {
        guard canApply else { return }
        let updates = Dictionary(uniqueKeysWithValues: assignments.map { ($0.note.id, $0.lyric) })
        onApply(updates)
        dismiss()
    }
}
