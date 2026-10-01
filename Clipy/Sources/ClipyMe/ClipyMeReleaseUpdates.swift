import AppKit

/// Release notices only: never downloads, installs or executes an update.
final class ClipyMeReleaseUpdates {
    static let repositoryURL = URL(string: "https://github.com/khandelwaly940/clipy.me")!
    static let endpoint = URL(string: "https://api.github.com/repos/khandelwaly940/clipy.me/releases/latest")!
    static let lastAttemptKey = "ClipyMe.updates.lastAttempt"
    static let lastSuccessKey = "ClipyMe.updates.lastSuccess"
    private let defaults: UserDefaults
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var checking = false
    private let session: URLSession

    init(defaults: UserDefaults = .standard, domainName: String = Bundle.main.bundleIdentifier ?? "local.clipyme.app") {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        if saved[Constants.Update.enableAutomaticCheck] == nil {
            defaults.set(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true,
                         forKey: Constants.Update.enableAutomaticCheck)
        }
        if saved[Constants.Update.checkInterval] == nil {
            let previous = defaults.double(forKey: "SUScheduledCheckInterval")
            defaults.set(max(86_400, previous), forKey: Constants.Update.checkInterval)
        }
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        session.invalidateAndCancel()
    }

    static func nextDelay(defaults: UserDefaults, now: Date = Date()) -> TimeInterval? {
        guard defaults.bool(forKey: Constants.Update.enableAutomaticCheck) else { return nil }
        let interval = max(86_400, defaults.double(forKey: Constants.Update.checkInterval))
        let elapsed = now.timeIntervalSince1970 - defaults.double(forKey: lastAttemptKey)
        return max(10, interval - elapsed)
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil else { return false }
        return version.compare(current, options: .numeric) == .orderedDescending
    }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.schedule() }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        guard !checking, let delay = Self.nextDelay(defaults: defaults) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.check(manual: false) }
        timer?.tolerance = 60
    }

    func check(manual: Bool) {
        guard !checking else { return }
        if !manual && !defaults.bool(forKey: Constants.Update.enableAutomaticCheck) { return }
        checking = true
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastAttemptKey)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClipyMe/\(Bundle.main.appVersion ?? "unknown")", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                defer { self.schedule() }
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, data.count < 1_000_000,
                      let release = try? JSONDecoder().decode(Release.self, from: data),
                      !release.draft, !release.prerelease else {
                    if manual { self.show(message: "Could not check for updates", detail: "Please try again later or visit the ClipyMe releases page.") }
                    return
                }
                self.defaults.set(Date(), forKey: Self.lastSuccessKey)
                guard Self.isNewer(release.tagName, than: Bundle.main.appVersion ?? "0.0") else {
                    if manual { self.show(message: "ClipyMe is up to date", detail: "You are using v\(Bundle.main.appVersion ?? "").") }
                    return
                }
                guard manual || (self.defaults.bool(forKey: Constants.Update.enableAutomaticCheck) &&
                    self.defaults.string(forKey: "ClipyMe.updates.notifiedVersion") != release.tagName) else { return }
                // An automatic notice waits until a menu/modal is no longer being used.
                let notice: () -> Void = { [weak self] in self?.offer(release.tagName, manual: manual) }
                RunLoop.main.perform(inModes: [.default], block: notice)
            }
        }.resume()
    }

    private func offer(_ version: String, manual: Bool) {
        guard manual || defaults.bool(forKey: Constants.Update.enableAutomaticCheck) else { return }
        if NSApp.modalWindow != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.offer(version, manual: manual) }
            return
        }
        defaults.set(version, forKey: "ClipyMe.updates.notifiedVersion")
        let alert = NSAlert()
        alert.messageText = "ClipyMe \(version) is available"
        alert.informativeText = "View the release notes and installation command. Your current app will not change until you choose to update."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.repositoryURL.appendingPathComponent("releases/latest"))
        }
    }

    private func show(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease }
    }
}
