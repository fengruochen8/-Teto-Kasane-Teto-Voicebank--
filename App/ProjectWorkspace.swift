import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let tetoProject = UTType(exportedAs: "com.fengruochen8.tetomelody.project", conformingTo: .json)
    static let wavAudio = UTType(filenameExtension: "wav") ?? .audio
}

private struct WorkspaceFile: FileDocument {
    static var readableContentTypes: [UTType] { [.tetoProject, .wavAudio] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct ProjectWorkspace: View {
    @StateObject private var model = StudioModel()
    @State private var isNamingProject = false
    @State private var isImportingFile = false
    @State private var isExportingFile = false
    @State private var inputKind = ImportKind.project
    @State private var exportRequest: ExportRequest?

    private enum ImportKind {
        case project
        case voicebank

        var types: [UTType] {
            switch self {
            case .project: return [.tetoProject]
            case .voicebank: return [.zip]
            }
        }
    }

    private struct ExportRequest {
        let file: WorkspaceFile
        let type: UTType
        let filename: String
        let projectID: UUID?
    }

    var body: some View {
        Group {
            if let record = model.currentProject {
                StudioView(
                    model: model,
                    onNew: { isNamingProject = true },
                    onOpen: { chooseFile(.project) },
                    onSave: { saveProject(asCopy: false) },
                    onSaveAs: { saveProject(asCopy: true) },
                    onImportVoicebank: { chooseFile(.voicebank) },
                    onExportWave: { Task { await exportWave() } }
                )
                .id(record.id)
            } else {
                WelcomeView(
                    projects: model.recentProjects,
                    onNew: { isNamingProject = true },
                    onOpen: { chooseFile(.project) },
                    onExample: { model.createProject(named: "示例旋律", melody: .example) },
                    onRecent: { model.openLocalProject($0) }
                )
            }
        }
        .disabled(model.isHandlingProjectFile)
        .overlay {
            if model.isHandlingProjectFile {
                ProgressView("正在处理工程…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .preferredColorScheme(.dark)
        .tint(PianoRoll.accent)
        .task { model.loadProjectLibrary() }
        .sheet(isPresented: $isNamingProject) {
            NewProjectSheet { model.createProject(named: $0) }
                .presentationDetents([.height(225)])
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: inputKind.types, onCompletion: finishImport)
        .fileExporter(
            isPresented: $isExportingFile, document: exportRequest?.file,
            contentType: exportRequest?.type ?? .tetoProject,
            defaultFilename: exportRequest?.filename,
            onCompletion: finishExport
        )
        .onOpenURL { url in
            if url.isFileURL, url.pathExtension.lowercased() == "tetomelody" {
                Task { await model.openExternalProject(url) }
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func chooseFile(_ kind: ImportKind) {
        guard !model.isBusy else { return }
        inputKind = kind
        isImportingFile = true
    }

    private func finishImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            switch inputKind {
            case .project:
                Task { await model.openExternalProject(url) }
            case .voicebank:
                Task { await model.importZIP(url) }
            }
        case .failure(let error):
            showFileError(error)
        }
    }

    private func saveProject(asCopy: Bool) {
        guard !model.isBusy, let record = model.currentProject else { return }
        if !asCopy, model.canSaveToSource {
            Task { await model.saveToSource() }
            return
        }
        do {
            let data = try record.document.encoded()
            exportRequest = ExportRequest(
                file: WorkspaceFile(data: data), type: .tetoProject,
                filename: filename(record.document.name), projectID: record.id
            )
            isExportingFile = true
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func exportWave() async {
        guard let record = model.currentProject, let data = await model.renderedAudio() else { return }
        exportRequest = ExportRequest(
            file: WorkspaceFile(data: data), type: .wavAudio,
            filename: filename(record.document.name), projectID: nil
        )
        isExportingFile = true
    }

    private func finishExport(_ result: Result<URL, Error>) {
        let completed = exportRequest
        exportRequest = nil
        switch result {
        case .success(let url):
            if let projectID = completed?.projectID {
                model.recordProjectExport(to: url, projectID: projectID)
            }
        case .failure(let error):
            showFileError(error)
        }
    }

    private func showFileError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != CocoaError.Code.userCancelled.rawValue {
            model.errorMessage = error.localizedDescription
        }
    }

    private func filename(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: separators).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "旋律草稿" : cleaned
    }
}

@MainActor
private struct WelcomeView: View {
    let projects: [LocalProject]
    let onNew: () -> Void
    let onOpen: () -> Void
    let onExample: () -> Void
    let onRecent: (LocalProject) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                appTitle
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { newCard; openCard }
                    VStack(spacing: 12) { newCard; openCard }
                }
                recent
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.07, green: 0.11, blue: 0.15).ignoresSafeArea())
    }

    private var appTitle: some View {
        HStack(spacing: 16) {
            Image(systemName: "pianokeys")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(PianoRoll.accent, in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            Text("旋律草稿")
                .font(.system(size: 38, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var newCard: some View {
        actionCard("新建工程", detail: "从空白旋律开始", icon: "plus", highlighted: true, action: onNew)
    }

    private var openCard: some View {
        actionCard("打开工程", detail: "从「文件」打开 .tetomelody", icon: "folder", highlighted: false, action: onOpen)
    }

    private func actionCard(_ title: String, detail: String, icon: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(PianoRoll.accent)
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(minWidth: 214, maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                highlighted ? PianoRoll.accent.opacity(0.11) : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(highlighted ? PianoRoll.accent.opacity(0.50) : Color.white.opacity(0.10))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近工程").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("打开示例", systemImage: "music.note", action: onExample)
                    .buttonStyle(.bordered)
            }
            if projects.isEmpty {
                Text("新建或打开的工程会显示在这里。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(projects) { record in
                        Button { onRecent(record) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list").foregroundStyle(PianoRoll.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.document.name).font(.headline).lineLimit(1)
                                    Text("\(record.document.melody.notes.count)个音符 · \(record.document.melody.tempo) BPM")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(record.updatedAt, format: .dateTime.month().day())
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

@MainActor
private struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var name = ""
    let onCreate: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("工程名称", text: $name)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit(create)
            }
            .navigationTitle("新建工程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建", action: create)
                }
            }
        }
        .onAppear { titleFocused = true }
    }

    private func create() {
        onCreate(name)
        dismiss()
    }
}