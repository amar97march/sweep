import AppKit
import SwiftUI
import SweepCore
import SweepScanners

/// What Sweep found of each tool it works with, read on a background thread.
@MainActor
@Observable
final class IntegrationsModel {
    struct Tool: Identifiable, Equatable {
        enum Kind: String { case ollama, lmStudio, huggingFace, docker }
        enum State: Equatable {
            case notFound
            case found
            case notRunning
            case running(String)
        }

        let kind: Kind
        let name: String
        let purpose: String
        var app: String?
        var location: ToolLocation?
        var bytes: UInt64?
        var state: State
        var id: Kind { kind }
    }

    private(set) var tools: [Tool] = []
    private(set) var isRefreshing = false

    func refresh(_ locations: ToolLocations) {
        isRefreshing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let tools = Self.detect(locations)
            await MainActor.run {
                self?.tools = tools
                self?.isRefreshing = false
            }
        }
    }

    nonisolated static func detect(_ locations: ToolLocations) -> [Tool] {
        let finder = ToolFinder(environment: .live(), overrides: locations)
        func folder(_ location: ToolLocation, app: String?, cli: String? = nil) -> (ToolLocation?, UInt64?, Tool.State) {
            let exists = FileManager.default.fileExists(atPath: location.path)
            let state: Tool.State = exists || app != nil || cli != nil ? .found : .notFound
            return (location, exists ? Measure.size(location.path) : nil, state)
        }
        let ollama = folder(finder.ollamaModels, app: finder.ollamaApp, cli: finder.ollamaCLI)
        let lmStudio = folder(finder.lmStudioModels[0], app: finder.lmStudioApp)
        let huggingFace = folder(finder.huggingFaceHub, app: nil)

        var docker = Tool(kind: .docker, name: "Docker", purpose: "Junk Files offers Docker's build cache, unused images and stopped containers.",
                          app: finder.dockerApp, location: finder.dockerCLI, state: .notFound)
        if let cli = finder.dockerCLI?.path {
            let info = Shell.run(cli, ["version", "--format", "{{.Server.Version}}"], timeout: 8)
            let version = info.output.trimmingCharacters(in: .whitespacesAndNewlines)
            docker.state = info.status == 0 && !version.isEmpty ? .running(version) : .notRunning
            docker.bytes = finder.dockerDiskImage.map(Measure.allocated)
        } else if finder.dockerApp != nil {
            docker.state = .notRunning
        }
        return [
            Tool(kind: .ollama, name: "Ollama", purpose: "Junk Files lists Ollama models and leftover model files.",
                 app: finder.ollamaApp, location: ollama.0, bytes: ollama.1, state: ollama.2),
            Tool(kind: .lmStudio, name: "LM Studio", purpose: "Junk Files lists downloaded LM Studio models.",
                 app: finder.lmStudioApp, location: lmStudio.0, bytes: lmStudio.1, state: lmStudio.2),
            Tool(kind: .huggingFace, name: "Hugging Face", purpose: "Junk Files lists cached models and datasets.",
                 app: nil, location: huggingFace.0, bytes: huggingFace.1, state: huggingFace.2),
            docker,
        ]
    }
}

/// Settings → Integrations: the AI and developer tools Sweep cleans up after, where it found their files,
/// and how to point it somewhere else.
struct IntegrationsSettings: View {
    @Bindable var settings: AppSettings
    @State private var model = IntegrationsModel()

    var body: some View {
        Form {
            Section {
                ForEach(model.tools.filter { $0.kind != .docker }) { tool in row(tool) }
            } header: {
                Text("AI models")
            } footer: {
                Text("Sweep follows each app's own settings and environment variables to find its models. Removed models go to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.tools.filter { $0.kind == .docker }) { tool in row(tool) }
            } header: {
                Text("Containers")
            } footer: {
                Text("Works with Docker Desktop, OrbStack, Colima and Homebrew installs. Volumes are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if model.tools.isEmpty { ProgressView().controlSize(.small) }
        }
        .onAppear { model.refresh(settings.toolLocations) }
        .onChange(of: settings.toolLocations) { _, locations in model.refresh(locations) }
        // Docker may have been started (or quit) while Sweep was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh(settings.toolLocations)
        }
    }

    private func row(_ tool: IntegrationsModel.Tool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if let app = tool.app {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable()
                    } else {
                        Image(systemName: tool.kind == .docker ? "shippingbox.fill" : "brain")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ModuleKind.cleanup.theme.gradient))
                    }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                    Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(state: tool.state)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let location = tool.location {
                    HStack(spacing: 6) {
                        Image(systemName: tool.kind == .docker ? "terminal" : "folder").foregroundStyle(.secondary)
                        Text((location.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text("·").foregroundStyle(.secondary)
                        Text(locationNote(tool, location)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout)
                }
                HStack(spacing: 8) {
                    if tool.kind == .docker {
                        if tool.state == .notRunning, let app = tool.app {
                            Button("Open \((app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))") {
                                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: .init())
                            }
                        }
                        Button(tool.location == nil ? "Choose Command…" : "Change…") { chooseDockerCommand() }
                        Button("Check Again") { model.refresh(settings.toolLocations) }
                    } else {
                        Button(tool.location.map { FileManager.default.fileExists(atPath: $0.path) } == true ? "Change…" : "Choose Folder…") {
                            chooseFolder(for: tool.kind)
                        }
                        if let location = tool.location, FileManager.default.fileExists(atPath: location.path) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location.path)]) }
                        }
                    }
                    if tool.location?.origin == .sweep {
                        Button("Use Automatic") { reset(tool.kind) }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(.leading, 38)
        }
        .padding(.vertical, 3)
    }

    private func locationNote(_ tool: IntegrationsModel.Tool, _ location: ToolLocation) -> String {
        var parts = [location.origin.rawValue]
        if let bytes = tool.bytes {
            parts.append(tool.kind == .docker ? "disk image uses \(ByteFormat.string(bytes))" : "\(ByteFormat.string(bytes)) on this Mac")
        } else if tool.kind != .docker {
            parts.append("nothing there yet")
        }
        return parts.joined(separator: " · ")
    }

    private func chooseFolder(for kind: IntegrationsModel.Tool.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder where this app keeps its models."
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        switch kind {
        case .ollama: settings.toolLocations.ollamaModels = path
        case .lmStudio: settings.toolLocations.lmStudioModels = path
        case .huggingFace: settings.toolLocations.huggingFaceCache = path
        case .docker: break
        }
    }

    private func chooseDockerCommand() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use Command"
        panel.message = "Choose the docker command-line tool."
        guard panel.runModal() == .OK, let path = panel.url?.path, FileManager.default.isExecutableFile(atPath: path) else { return }
        settings.toolLocations.dockerCLI = path
    }

    private func reset(_ kind: IntegrationsModel.Tool.Kind) {
        switch kind {
        case .ollama: settings.toolLocations.ollamaModels = nil
        case .lmStudio: settings.toolLocations.lmStudioModels = nil
        case .huggingFace: settings.toolLocations.huggingFaceCache = nil
        case .docker: settings.toolLocations.dockerCLI = nil
        }
    }
}

struct StatusPill: View {
    let state: IntegrationsModel.Tool.State

    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .notFound: ("Not installed", Color.white.opacity(0.6))
        case .found: ("Connected", Color(hex: 0x14E3A1))
        case .notRunning: ("Not running", Color(hex: 0xFFB830))
        case .running(let version): ("Running · \(version)", Color(hex: 0x14E3A1))
        }
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}
