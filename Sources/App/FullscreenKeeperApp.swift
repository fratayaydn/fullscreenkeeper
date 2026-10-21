// FullscreenKeeper.app: settings for the fullscreenkeeperd background agent.
// Only the agent reads and changes other apps' windows.
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os.log

private let updateLog = OSLog(subsystem: "io.github.fratayaydn.fullscreenkeeper", category: "updater")

// Each callback owns its reply until completion, including after a timeout. The semaphore publishes the result.
final class NotificationReply<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func complete(_ result: Result<Value, Error>) {
        self.result = result
        done.signal()
    }

    func wait(_ step: String, deadline: DispatchTime = .now() + 30) throws -> Value {
        guard done.wait(timeout: deadline) == .success, let result else {
            os_log("%{public}@ timed out", log: updateLog, type: .error, step)
            throw NSError(domain: "FullscreenKeeper.NotificationTimeout", code: 1)
        }
        return try result.get()
    }
}

private func notificationStatus(_ center: UNUserNotificationCenter) throws -> UNAuthorizationStatus {
    let reply = NotificationReply<UNAuthorizationStatus>()
    center.getNotificationSettings { reply.complete(.success($0.authorizationStatus)) }
    return try reply.wait("Notification settings")
}

private func authorizeUpdateNotifications() throws {
    let reply = NotificationReply<Bool>()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error { reply.complete(.failure(error)) }
        else { reply.complete(.success(granted)) }
    }
    _ = try reply.wait("Notification authorization")
}

private func postUpdateNotification(_ request: UNNotificationRequest) throws {
    let reply = NotificationReply<Void>()
    UNUserNotificationCenter.current().add(request) { error in
        if let error { reply.complete(.failure(error)) }
        else { reply.complete(.success(())) }
    }
    try reply.wait("Post notification")
}

func notifyUpdate(
    _ arguments: [String],
    status: () throws -> UNAuthorizationStatus = { try notificationStatus(.current()) },
    authorize: () throws -> Void = authorizeUpdateNotifications,
    post: (UNNotificationRequest) throws -> Void = postUpdateNotification
) -> Int32 {
    guard arguments.count == 4, arguments[1] == "--notify-update",
          arguments[3] == "--installed" || arguments[3] == "--available" else { return 2 }
    let version = arguments[2]
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), parts.allSatisfy({ part in
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
    }) else { return 2 }

    do {
        var authorization = try status()
        if authorization == .notDetermined {
            try authorize()
            authorization = try status()
        }
        guard authorization == .authorized || authorization == .provisional else {
            os_log("Notifications are not allowed", log: updateLog, type: .info)
            return 0
        }
        let installed = arguments[3] == "--installed"
        let content = UNMutableNotificationContent()
        content.title = installed ? "FullscreenKeeper updated to \(version)"
            : "FullscreenKeeper \(version) is available"
        content.body = installed ? "The update was installed successfully." : "Open settings to install the update."
        let request = UNNotificationRequest(identifier: "release-update", content: content, trigger: nil)
        try post(request)
        os_log("Release notification posted", log: updateLog, type: .info)
        return 0
    } catch {
        let error = error as NSError
        os_log("Release notification failed: %{public}@ %ld", log: updateLog, type: .error, error.domain, error.code)
        return 1
    }
}

let agentPlistName = "io.github.fratayaydn.fullscreenkeeper.agent.plist"
let updaterPlistName = "io.github.fratayaydn.fullscreenkeeper.updater.plist"
let updaterJob = "gui/\(getuid())/io.github.fratayaydn.fullscreenkeeper.updater"
let agentJob = "gui/\(getuid())/io.github.fratayaydn.fullscreenkeeper.agent"
let settingsChangedNotification = Notification.Name("io.github.fratayaydn.fullscreenkeeper.SettingsChanged")
let statusChangedNotification = Notification.Name("io.github.fratayaydn.fullscreenkeeper.StatusChanged")
let registeredBuildKey = "RegisteredBuildID"
let currentBuildID = Bundle.main.object(forInfoDictionaryKey: "FKBuildID") as? String ?? ""
let rememberedAppsType = UTType(exportedAs: "io.github.fratayaydn.fullscreenkeeper.remembered-apps", conformingTo: .data)

struct FeatureSettings {
    var reopenInFullScreen: Bool
    var forceFnF: Bool

    init(reopenValue: Any?, forceFnFValue: Any?) {
        reopenInFullScreen = (reopenValue as? NSNumber)?.boolValue ?? true
        forceFnF = (forceFnFValue as? NSNumber)?.boolValue ?? false
    }

    init(defaults: UserDefaults) {
        self.init(reopenValue: defaults.object(forKey: "ReopenInFullScreen"),
                  forceFnFValue: defaults.object(forKey: "ForceFnF"))
    }

    var registersAgent: Bool { reopenInFullScreen || forceFnF }

    mutating func requestRegistration() {
        if !registersAgent { reopenInFullScreen = true }
    }
}

// Permission checks run in the agent executable so macOS uses the agent's identity and fresh process state.
struct AgentPermissions {
    var accessibility = false

    mutating func check(run: (String) throws -> Int32) throws -> Bool {
        func granted(_ argument: String, name: String) throws -> Bool {
            let status = try run(argument)
            guard status == 0 || status == 1 else {
                throw NSError(domain: "FullscreenKeeper.Permission", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Could not check \(name) access (exit status \(status))."])
            }
            return status == 0
        }
        let newAccessibility = try granted("--check", name: "Accessibility")
        let restart = !accessibility && newAccessibility
        accessibility = newAccessibility
        return restart
    }
}

// Changing one feature must not re-register or restart an agent used by the other feature.
func reconcileLoginItems(_ settings: FeatureSettings, agentStatus: SMAppService.Status,
                         updaterStatus: SMAppService.Status, setEnabled: (Bool) throws -> Void) throws {
    let statuses = [agentStatus, updaterStatus]
    let registered = statuses.map { $0 == .enabled || $0 == .requiresApproval }
    if settings.registersAgent ? registered.contains(false) : registered.contains(true) {
        try setEnabled(settings.registersAgent)
    }
}

struct RememberedApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init(id: String, name: String) {
        self.id = id
        self.name = name
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }
}

// MARK: - Model

final class Model: ObservableObject {
    @Published var agentStatus = SMAppService.Status.notRegistered
    @Published private var permissions = AgentPermissions()
    var accessibilityGranted: Bool { permissions.accessibility }
    @Published private(set) var fnWatchActive: Bool?
    @Published var applications: [RememberedApp] = []
    @Published var ignoredApplications: [RememberedApp] = []
    @Published var errorMessage: String?
    @Published var automaticUpdates = true
    @Published var reopenInFullScreen = true
    @Published var forceFnF = false
    @Published var checkingUpdates = false
    @Published var latestVersion: String?
    @Published var lastUpdateCheck: Date?
    @Published var spaceEventsPath: String?
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    private let defaults = UserDefaults.standard
    private let agent = SMAppService.agent(plistName: agentPlistName)
    private var statusObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var statusReplyObserver: NSObjectProtocol?
    private var statusRequestID = UUID().uuidString

    init() {
        statusReplyObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.fratayaydn.fullscreenkeeper.StatusReply"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.object as? String == self.statusRequestID else { return }
            self.fnWatchActive = note.userInfo?["fnFWatch"] as? Bool
        }
        refresh()
        let wasEnabled = agentStatus == .enabled
        updateFeatureRegistration()
        reregisterAfterUpdate(wasEnabled: wasEnabled)
        checkPermissionAgain()
        statusObserver = DistributedNotificationCenter.default().addObserver(
            forName: statusChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
            self?.checkPermissionAgain()
        }
    }

    deinit {
        if let statusObserver { DistributedNotificationCenter.default().removeObserver(statusObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if let statusReplyObserver { DistributedNotificationCenter.default().removeObserver(statusReplyObserver) }
    }

    func refresh() {
        fnWatchActive = nil
        statusRequestID = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.github.fratayaydn.fullscreenkeeper.StatusRequest"),
            object: statusRequestID, deliverImmediately: true)
        agentStatus = agent.status
        defaults.synchronize()
        let features = FeatureSettings(defaults: defaults)
        reopenInFullScreen = features.reopenInFullScreen
        forceFnF = features.forceFnF
        automaticUpdates = defaults.object(forKey: "AutomaticallyInstallUpdates") == nil
            || defaults.bool(forKey: "AutomaticallyInstallUpdates")
        latestVersion = defaults.string(forKey: "LatestVersion")
        lastUpdateCheck = defaults.object(forKey: "LastUpdateCheck") as? Date
        spaceEventsPath = defaults.string(forKey: "SpaceEventsPath")
        let ignoredRecords = defaults.dictionary(forKey: "IgnoredApplications") as? [String: [String: Any]] ?? [:]
        let records = defaults.dictionary(forKey: "Applications") as? [String: [String: Any]] ?? [:]
        let fullscreenRecords = records.filter { $0.value["fullscreen"] as? Bool == true && ignoredRecords[$0.key] == nil }
        if reopenInFullScreen && fullscreenRecords.count != records.count { saveApplications(fullscreenRecords) }
        applications = fullscreenRecords.map { id, entry in
            RememberedApp(id: id, name: entry["name"] as? String ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        ignoredApplications = ignoredRecords.map { id, entry in
            RememberedApp(id: id, name: entry["name"] as? String ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        defaults.synchronize()
        var records = defaults.dictionary(forKey: "Applications") ?? [:]
        for id in ids { records.removeValue(forKey: id) }
        saveApplications(records)
        refresh()
    }

    func chooseIgnoredApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Ignore"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.ignoreApplications(at: panel.urls)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func ignore(_ ids: Set<String>) {
        let names = Dictionary(uniqueKeysWithValues: applications.filter { ids.contains($0.id) }.map { ($0.id, $0.name) })
        ignoreApplications(names)
    }

    private func ignoreApplications(at urls: [URL]) {
        var names: [String: String] = [:]
        for url in urls {
            guard url.isFileURL, url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, !id.isEmpty,
                  id != "io.github.fratayaydn.fullscreenkeeper" else { continue }
            names[id] = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        }
        ignoreApplications(names)
    }

    private func ignoreApplications(_ names: [String: String]) {
        guard !names.isEmpty else { return }
        defaults.synchronize()
        var ignoredRecords = defaults.dictionary(forKey: "IgnoredApplications") ?? [:]
        var records = defaults.dictionary(forKey: "Applications") ?? [:]
        for (id, name) in names {
            ignoredRecords[id] = ["name": name]
            records.removeValue(forKey: id)
        }
        defaults.set(ignoredRecords, forKey: "IgnoredApplications")
        saveApplications(records)
        refresh()
    }

    func ignoreDroppedApplications(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(rememberedAppsType.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: rememberedAppsType.identifier) { [weak self] data, _ in
                    guard let data, let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
                    DispatchQueue.main.async { self?.ignore(Set(ids)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { self?.ignoreApplications(at: [url]) }
                }
            }
        }
        return accepted
    }

    func unignore(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        defaults.synchronize()
        var records = defaults.dictionary(forKey: "IgnoredApplications") ?? [:]
        for id in ids { records.removeValue(forKey: id) }
        defaults.set(records, forKey: "IgnoredApplications")
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(settingsChangedNotification, object: nil, deliverImmediately: true)
        refresh()
    }

    private func saveApplications(_ records: [String: Any]) {
        defaults.set(records, forKey: "Applications")
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(settingsChangedNotification, object: nil, deliverImmediately: true)
    }

    var isEnabled: Bool { reopenInFullScreen || forceFnF }

    private func updateFeatureRegistration() {
        do {
            try reconcileLoginItems(FeatureSettings(defaults: defaults), agentStatus: agent.status,
                                    updaterStatus: SMAppService.agent(plistName: updaterPlistName).status,
                                    setEnabled: setLoginItemsEnabled)
        } catch {
            errorMessage = "Could not update FullscreenKeeper's background jobs: \(error.localizedDescription)"
        }
        agentStatus = agent.status
    }

    private func setFeature(_ on: Bool, key: String) {
        defaults.set(on, forKey: key)
        defaults.synchronize()
        // Let a running agent tear down the feature before unregistering the jobs if both are off.
        DistributedNotificationCenter.default().postNotificationName(settingsChangedNotification, object: nil, deliverImmediately: true)
        updateFeatureRegistration()
        refresh()
    }

    func setReopenInFullScreen(_ on: Bool) {
        setFeature(on, key: "ReopenInFullScreen")
    }

    var availableVersion: String? {
        guard let latestVersion else { return nil }
        let latest = latestVersion.split(separator: ".").map(String.init)
        let current = version.split(separator: ".").map(String.init)
        for index in 0..<3 {
            let a = index < latest.count ? latest[index] : "0"
            let b = index < current.count ? current[index] : "0"
            let comparison = a.compare(b, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending ? latestVersion : nil }
        }
        return nil
    }

    var lastCheckedText: String {
        guard let lastUpdateCheck else { return "Last checked: never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastUpdateCheck, relativeTo: Date()))"
    }

    func setAutomaticUpdates(_ on: Bool) {
        defaults.set(on, forKey: "AutomaticallyInstallUpdates")
        defaults.synchronize()
        automaticUpdates = on
    }

    func setForceFnF(_ on: Bool) {
        setFeature(on, key: "ForceFnF")
        if on { checkPermissionAgain() }
    }

    func checkUpdates(install: Bool = false) {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fullscreenkeeperd")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--update-check", "--force"] + (install ? ["--install"] : [])
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var message: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationReason != .exit || process.terminationStatus != 0 {
                    message = "Could not complete the update. Try again later."
                }
            } catch {
                message = "Could not check for updates: \(error.localizedDescription)"
            }
            let result = message
            DispatchQueue.main.async {
                self?.checkingUpdates = false
                self?.errorMessage = result
                self?.refresh()
            }
        }
    }

    func openAccessibility() {
        do {
            _ = try runAgentCommand("--prompt")
        } catch {
            errorMessage = "Could not request Accessibility access: \(error.localizedDescription)"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func checkPermissionAgain() {
        do {
            let restart = try permissions.check(run: runAgentCommand)
            agentStatus = agent.status
            // Restart once when Accessibility becomes granted.
            if restart && agentStatus == .enabled {
                DispatchQueue.global().async { launchctl(["kickstart", "-k", agentJob]) }
            }
        } catch {
            errorMessage = "Could not check permissions: \(error.localizedDescription)"
        }
    }

    private func runAgentCommand(_ argument: String) throws -> Int32 {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fullscreenkeeperd")
        process.arguments = [argument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : -1
    }

    // Local signing pins launchd to a build, so refresh its launch constraint after an update.
    private func reregisterAfterUpdate(wasEnabled: Bool) {
        guard defaults.string(forKey: registeredBuildKey) != currentBuildID else { return }
        defaults.set(currentBuildID, forKey: registeredBuildKey)
        guard wasEnabled, FeatureSettings(defaults: defaults).registersAgent, agent.status == .enabled else { return }
        DispatchQueue.global().async { [weak self] in
            reregisterAgent()
            if !agentIsRunning() { reregisterAgent() }
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}

// MARK: - Window

// Use the grouped Form's native backdrop between its separate sections.
private struct SettingsBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .withinWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var selectedApps: Set<String> = []
    @State private var selectedIgnoredApps: Set<String> = []

    private var applicationListHeight: CGFloat {
        // Keep 10 points of padding outside the scrollable rows at each edge.
        CGFloat(min(max(model.applications.count, model.ignoredApplications.count, 4), 7)) * 24 + 20
    }

    var body: some View {
        VStack(spacing: 10) {
            Form {
                Section {
                    // Two texts in a Form row label: macOS shows the second one as the row's grey description.
                    Toggle(isOn: Binding(get: { model.reopenInFullScreen }, set: { model.setReopenInFullScreen($0) })) {
                        Text("Remember full screen")
                        Text("Opens an app in full screen again if you quit it in full screen.")
                    }
                    Toggle(isOn: Binding(get: { model.forceFnF }, set: { model.setForceFnF($0) })) {
                        Text("Force fn-F")
                        Text("Makes fn-F switch full screen in every app, even apps that ignore it.")
                    }
                    statusRow
                    if model.forceFnF && model.accessibilityGranted && model.fnWatchActive == false {
                        StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                                  title: "Force fn-F Is Not Available",
                                  detail: "macOS did not allow FullscreenKeeper to watch the fn key on this Mac.")
                    }
                    if model.reopenInFullScreen, let path = model.spaceEventsPath, path != "windowserver transitions" {
                        StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                                  title: "Running in compatibility mode.",
                                  detail: "A macOS update changed something FullscreenKeeper uses; it still works, an update will restore the lighter mode.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            // The stack supplies the section gap instead of the Form's bottom margin.
            .padding(.bottom, -20)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apps That Reopen in Full Screen")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ApplicationList(applications: model.applications, selection: $selectedApps,
                                    height: applicationListHeight,
                                    emptyMessage: "Quit an app in full screen to add it.",
                                    ignore: { model.ignore(selectedApps) },
                                    drag: { app in
                                        let ids = selectedApps.contains(app.id) ? selectedApps : [app.id]
                                        let provider = NSItemProvider()
                                        provider.registerDataRepresentation(forTypeIdentifier: rememberedAppsType.identifier,
                                                                            visibility: .ownProcess) { completion in
                                            completion(try? JSONEncoder().encode(Array(ids)), nil)
                                            return nil
                                        }
                                        return provider
                                    }, removeLabel: "Forget selected apps") {
                        model.forget(selectedApps)
                        selectedApps.removeAll()
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ignored Apps")
                        .help("Never remembered or restored in full screen. Force fn-F still works in these apps.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ApplicationList(applications: model.ignoredApplications, selection: $selectedIgnoredApps,
                                    height: applicationListHeight,
                                    emptyMessage: "No ignored apps.", add: { model.chooseIgnoredApplications() },
                                    drop: { model.ignoreDroppedApplications($0) },
                                    removeLabel: "Remove selected ignored apps") {
                        model.unignore(selectedIgnoredApps)
                        selectedIgnoredApps.removeAll()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.02))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
            }
            .padding(.horizontal, 20)

            Form {
                Section("Updates") {
                    Toggle(isOn: Binding(get: { model.automaticUpdates }, set: { model.setAutomaticUpdates($0) })) {
                        Text("Install updates automatically")
                        Text("Only updates signed by the developer and notarized by Apple.")
                    }
                    HStack {
                        Text("Version \(model.version), \(model.lastCheckedText.lowercased().replacingOccurrences(of: "checked:", with: "checked"))")
                            .lineLimit(1)
                        Spacer()
                        Button(model.checkingUpdates ? "Checking..." : "Check Now") { model.checkUpdates() }
                            .disabled(model.checkingUpdates)
                    }
                    if !model.automaticUpdates, let version = model.availableVersion {
                        Button("Install \(version)") { model.checkUpdates(install: true) }
                            .disabled(model.checkingUpdates)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.regular)
        .frame(width: 720)
        .background(SettingsBackground())
        .onChange(of: model.applications.map(\.id)) { ids in
            selectedApps.formIntersection(ids)
        }
        .onChange(of: model.ignoredApplications.map(\.id)) { ids in
            selectedIgnoredApps.formIntersection(ids)
        }
        .alert("FullscreenKeeper", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var statusRow: some View {
        if !model.isEnabled {
            StatusRow(symbol: "circle", color: .secondary, title: "FullscreenKeeper Is Off",
                      detail: "Apps use their own window restoration behavior.")
        } else if !model.accessibilityGranted {
            StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                      title: "Accessibility Required",
                      detail: "FullscreenKeeper checks and sets full screen. Force fn-F also checks keys while fn is held. It doesn't read titles or contents. After allowing it, click Check Again.\n\nAlready in the list after an update? Remove it with the minus button and allow it again.",
                      action: ("Open Accessibility Settings...", { model.openAccessibility() }),
                      secondaryAction: ("Check Again", { model.checkPermissionAgain() }))
        } else if model.agentStatus == .enabled {
            StatusRow(symbol: "checkmark.circle.fill", color: .green, title: "FullscreenKeeper Is On",
                      detail: model.reopenInFullScreen && model.forceFnF
                          ? "Remembers full screen and makes fn-F work in every app."
                          : model.reopenInFullScreen ? "Remembers full screen."
                          : "Makes fn-F work in every app.",
                      doubleCheck: model.reopenInFullScreen && model.forceFnF)
        } else if model.agentStatus == .requiresApproval {
            StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow, title: "Approval Required",
                      detail: "Allow FullscreenKeeper under Allow in the Background so it can run without this window.",
                      action: ("Open Login Items...", { SMAppService.openSystemSettingsLoginItems() }))
        } else {
            StatusRow(symbol: "circle", color: .secondary, title: "FullscreenKeeper Is Off",
                      detail: "Apps use their own window restoration behavior.")
        }
    }
}

/// Shared native list and button bar for remembered and ignored applications.
struct ApplicationList: View {
    let applications: [RememberedApp]
    @Binding var selection: Set<String>
    let height: CGFloat
    let emptyMessage: String
    var add: (() -> Void)? = nil
    var ignore: (() -> Void)? = nil
    var drag: ((RememberedApp) -> NSItemProvider)? = nil
    var drop: (([NSItemProvider]) -> Bool)? = nil
    let removeLabel: String
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(applications, selection: $selection) { app in
                Group {
                    if let drag {
                        appRow(app).itemProvider { drag(app) }
                    } else {
                        appRow(app)
                    }
                }
                .tag(app.id)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            .listStyle(.plain)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(height: height)
            .overlay {
                if applications.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: drop == nil ? [] : [rememberedAppsType, .fileURL], isTargeted: nil) { providers in
                drop?(providers) ?? false
            }
            Divider()
            HStack {
                ControlGroup {
                    if let add {
                        Button(action: add) { Image(systemName: "plus") }
                            .accessibilityLabel("Ignore apps")
                            .help("Ignore apps")
                    }
                    Button(action: remove) { Image(systemName: "minus") }
                        .disabled(selection.isEmpty)
                        .accessibilityLabel(removeLabel)
                        .help(removeLabel)
                    if let ignore {
                        Button("Ignore", action: ignore)
                            .disabled(selection.isEmpty)
                            .help("Ignore selected apps")
                    }
                }
                .controlSize(.small)
                .fixedSize()
                Spacer()
            }
            .padding(5)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    private func appRow(_ app: RememberedApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(app.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A status line in the style of System Settings: symbol, title, explanation and an optional button.
struct StatusRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)? = nil
    var secondaryAction: (label: String, run: () -> Void)? = nil
    /// The symbol twice, slightly overlapping: both features are on.
    var doubleCheck = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if doubleCheck {
                    HStack(spacing: -5) {
                        Image(systemName: symbol)
                        Image(systemName: symbol)
                    }
                    .font(.system(size: 13.5))
                    .foregroundStyle(color)
                } else {
                    Image(systemName: symbol).foregroundStyle(color)
                }
            }
            .font(.system(size: 18))
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if action != nil || secondaryAction != nil {
                    HStack {
                        if let action { Button(action.label, action: action.run) }
                        if let secondaryAction { Button(secondaryAction.label, action: secondaryAction.run) }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Login items

// Remove the updater first, since removing the main job can terminate the background process.
func setLoginItemsEnabled(_ enabled: Bool) throws {
    let names = enabled ? [agentPlistName, updaterPlistName] : [updaterPlistName, agentPlistName]
    var firstError: Error?
    for name in names {
        let service = SMAppService.agent(plistName: name)
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            if firstError == nil { firstError = error }
        }
    }
    if let firstError { throw firstError }
}

@discardableResult
func launchctl(_ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Starts the agent once through launchd. After an update this makes launchd pin the agent to the new build;
/// without it the job can stay stuck with "needs LWCR update" (see scripts/install.sh).
func startAgentOnce() { launchctl(["kickstart", agentJob]) }

func agentIsRunning() -> Bool { launchctl(["print", agentJob]).contains("state = running") }

/// Unregister, wait until launchd has dropped the job, register and start once: the sequence that refreshes
/// the agent's launch constraint after an update (see scripts/install.sh).
func reregisterAgent() {
    try? setLoginItemsEnabled(false)
    for job in [updaterJob, agentJob] {
        for _ in 0..<70 where !launchctl(["print", job]).isEmpty { Thread.sleep(forTimeInterval: 0.5) }
    }
    Thread.sleep(forTimeInterval: 1)
    guard FeatureSettings(defaults: .standard).registersAgent else { return }
    try? setLoginItemsEnabled(true)
    startAgentOnce()
    Thread.sleep(forTimeInterval: 2)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `FullscreenKeeper --unregister` / `--register` (used by the Makefile): change the login item and quit.
        if CommandLine.arguments.contains("--unregister") {
            try? setLoginItemsEnabled(false)
            exit(0)
        }
        if CommandLine.arguments.contains("--register") {
            let defaults = UserDefaults.standard
            defaults.synchronize()
            var settings = FeatureSettings(defaults: defaults)
            settings.requestRegistration()
            defaults.set(settings.reopenInFullScreen, forKey: "ReopenInFullScreen")
            defaults.synchronize()
            do {
                try setLoginItemsEnabled(true)
                startAgentOnce()
                // This build is registered now; the window must not re-register it again (see reregisterAfterUpdate).
                UserDefaults.standard.set(currentBuildID, forKey: registeredBuildKey)
                UserDefaults.standard.synchronize()  // exit() would otherwise drop the unsaved value
                exit(0)
            } catch {
                FileHandle.standardError.write("FullscreenKeeper: could not register the background agent: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !NOTIFICATION_TESTS
@main
#endif
enum FullscreenKeeperMain {
    @MainActor
    static func main() {
        // Inspect notification arguments before creating NSApplication, a delegate or any SwiftUI state.
        if CommandLine.arguments.contains("--notify-update") {
            exit(notifyUpdate(CommandLine.arguments))
        }
        FullscreenKeeperApp.main()
    }
}

struct FullscreenKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("FullscreenKeeper", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
