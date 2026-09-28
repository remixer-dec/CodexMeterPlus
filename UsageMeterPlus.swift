import Cocoa
import Foundation
import UniformTypeIdentifiers

// UsageMeterPlus.swift
// Dependency-free macOS menu-bar Codex + Claude quota meter.
// Build: xcrun swiftc -O -framework Cocoa UsageMeterPlus.swift -o UsageMeterPlus
//
// Auth copies:
//   ~/Library/Application Support/UsageMeterPlus/accounts/
// Settings:
//   ~/Library/Application Support/UsageMeterPlus/settings.json
//
// Network destinations are limited to OpenAI's OAuth refresh endpoint,
// ChatGPT's Codex usage endpoint, Anthropic's OAuth refresh endpoint and
// Anthropic's Claude usage endpoint.

private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
private let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
// codexOAuthClientID is not a secret. The codexOAuthClientID used is a public OAuth client identifier associated with 
// the official Codex login flow. Codex itself exposes a CLIENT_ID/oauth_client_id() in its open-source login module,
// and the same client ID is visible in the browser authorization URL during normal Codex sign-in.
private let codexOAuthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
private let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let claudeRefreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
// Like the Codex one, claudeOAuthClientID is the public OAuth client identifier of the official Claude Code login
// flow (visible in the claude.ai authorization URL during normal Claude Code sign-in). It is not a secret.
private let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let claudeOAuthScopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers"
private let claudeOAuthBeta = "oauth-2025-04-20"
private let fiveHours: TimeInterval = 5 * 60 * 60
private let sevenDays: TimeInterval = 7 * 24 * 60 * 60

// MARK: - Model

private struct UsageWindow {
    let remaining: Double       // 0...1, intentionally NOT percent used
    let resetAt: Date?          // nil when the window has not started yet (Claude reports no reset then)
    let duration: TimeInterval

    var resetRemaining: Double {
        guard duration > 0, let resetAt else { return 0 }
        return min(1, max(0, resetAt.timeIntervalSinceNow / duration))
    }
}

private struct UsageSnapshot {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let plan: String?
    let fetchedAt: Date
}

private enum Provider: Equatable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var filePrefix: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }
}

private struct Account: Equatable {
    let file: URL
    let provider: Provider
}

private enum MeterError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// MARK: - Settings + account storage

private struct SettingsData: Codable {
    var barColor: String = "blue"
    var accountOrder: [String] = []
}

private final class SettingsStore {
    let baseDirectory: URL
    let file: URL
    private(set) var data = SettingsData()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDirectory = support.appendingPathComponent("UsageMeterPlus", isDirectory: true)
        file = baseDirectory.appendingPathComponent("settings.json")
        // Carry accounts and settings over from the CodexMeterPlus era.
        let legacy = support.appendingPathComponent("CodexMeterPlus", isDirectory: true)
        if !FileManager.default.fileExists(atPath: baseDirectory.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: baseDirectory)
        }
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)
        load()
    }

    func setBarColor(_ key: String) {
        data.barColor = key
        save()
    }

    func setAccountOrder(_ names: [String]) {
        data.accountOrder = names
        save()
    }

    private func load() {
        guard let bytes = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: bytes) else { return }
        data = decoded
        // v1 used "system", which could duplicate blue/red depending on macOS Accent Color.
        if data.barColor == "system" {
            data.barColor = "blue"
            save()
        }
    }

    private func save() {
        guard let bytes = try? JSONEncoder().encode(data) else { return }
        try? bytes.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private final class AccountStore {
    let directory: URL
    private let settings: SettingsStore
    private(set) var accounts: [Account] = []

    init(settings: SettingsStore) {
        self.settings = settings
        directory = settings.baseDirectory.appendingPathComponent("accounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let valid = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> Account? in
                guard let object = try? jsonObject(url), let provider = providerOf(object) else { return nil }
                return Account(file: url, provider: provider)
            }

        var order = settings.data.accountOrder
        let validNames = Set(valid.map(\.file.lastPathComponent))
        order.removeAll { !validNames.contains($0) }
        for account in valid.sorted(by: { $0.file.lastPathComponent < $1.file.lastPathComponent }) {
            if !order.contains(account.file.lastPathComponent) {
                order.append(account.file.lastPathComponent)
            }
        }
        settings.setAccountOrder(order)

        let byName = Dictionary(uniqueKeysWithValues: valid.map { ($0.file.lastPathComponent, $0) })
        accounts = order.compactMap { byName[$0] }
    }

    @discardableResult
    func importAuth(from source: URL) throws -> Account {
        let object = try jsonObject(source)
        let provider: Provider
        if let tokens = tokenDictionary(object),
           tokens["access_token"] as? String != nil,
           tokens["refresh_token"] as? String != nil {
            provider = .codex
        } else if let oauth = claudeOAuthDictionary(object),
                  oauth["accessToken"] as? String != nil,
                  oauth["refreshToken"] as? String != nil {
            provider = .claude
        } else {
            throw MeterError.message(
                "That file is neither a Codex ChatGPT OAuth auth.json nor a Claude Code OAuth credentials JSON."
            )
        }

        var number = 1
        var destination: URL
        repeat {
            destination = directory.appendingPathComponent("\(provider.filePrefix)-\(number).json")
            number += 1
        } while FileManager.default.fileExists(atPath: destination.path)

        let bytes = try Data(contentsOf: source)
        try bytes.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        var order = settings.data.accountOrder
        order.append(destination.lastPathComponent)
        settings.setAccountOrder(order)
        reload()

        guard let account = accounts.first(where: { $0.file == destination }) else {
            throw MeterError.message("Imported account could not be loaded.")
        }
        return account
    }

    func remove(_ account: Account) throws {
        try FileManager.default.removeItem(at: account.file)
        var order = settings.data.accountOrder
        order.removeAll { $0 == account.file.lastPathComponent }
        settings.setAccountOrder(order)
        reload()
    }
}

// MARK: - API

private final class UsageClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func fetch(account: Account, completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        switch account.provider {
        case .codex: fetchCodex(account: account, completion: completion)
        case .claude: fetchClaude(account: account, completion: completion)
        }
    }

    private func fetchCodex(account: Account, completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let object = try jsonObject(account.file)
                guard let tokens = tokenDictionary(object),
                      let accountID = tokens["account_id"] as? String,
                      !accountID.isEmpty else {
                    throw MeterError.message("Missing tokens.account_id in \(account.file.lastPathComponent).")
                }

                self.validAccessToken(authObject: object, file: account.file) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let token):
                        self.fetchUsage(token: token, accountID: accountID, completion: completion)
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func validAccessToken(
        authObject: [String: Any],
        file: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let tokens = tokenDictionary(authObject),
              let access = tokens["access_token"] as? String else {
            completion(.failure(MeterError.message("Missing Codex access token.")))
            return
        }

        // Refresh five minutes early when an expiry claim is available.
        if let expiration = jwtExpiration(access), expiration.timeIntervalSinceNow > 5 * 60 {
            completion(.success(access))
            return
        }
        if jwtExpiration(access) == nil {
            completion(.success(access))
            return
        }

        guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            completion(.failure(MeterError.message("Access token expired and no refresh token is present.")))
            return
        }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("UsageMeterPlus/3", forHTTPHeaderField: "User-Agent")

        let claims = jwtPayload(access)
        let clientID = (claims?["client_id"] as? String)
            ?? (claims?["azp"] as? String)
            ?? codexOAuthClientID

        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID
        ])

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(MeterError.message("No response from OAuth token endpoint.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(MeterError.message(
                    "OAuth refresh failed (HTTP \(http.statusCode)). Re-import/re-login this account."
                )))
                return
            }

            do {
                guard let refreshed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccess = refreshed["access_token"] as? String else {
                    throw MeterError.message("OAuth refresh response had no access_token.")
                }

                var updated = authObject
                var newTokens = tokens
                newTokens["access_token"] = newAccess
                if let newRefresh = refreshed["refresh_token"] as? String, !newRefresh.isEmpty {
                    newTokens["refresh_token"] = newRefresh
                }
                if let idToken = refreshed["id_token"] as? String, !idToken.isEmpty {
                    newTokens["id_token"] = idToken
                }
                updated["tokens"] = newTokens
                updated["last_refresh"] = ISO8601DateFormatter().string(from: Date())

                let output = try JSONSerialization.data(
                    withJSONObject: updated,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try output.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                completion(.success(newAccess))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func fetchUsage(
        token: String,
        accountID: String,
        completion: @escaping (Result<UsageSnapshot, Error>) -> Void
    ) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(MeterError.message("No response from Codex usage endpoint.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(MeterError.message("Usage request failed (HTTP \(http.statusCode)).")))
                return
            }

            do {
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MeterError.message("Unexpected usage response.")
                }
                completion(.success(parseUsage(root)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func fetchClaude(account: Account, completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let object = try jsonObject(account.file)
                let plan = claudeOAuthDictionary(object)?["subscriptionType"] as? String

                self.validClaudeAccessToken(authObject: object, file: account.file) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let token):
                        self.fetchClaudeUsage(token: token, plan: plan, completion: completion)
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func validClaudeAccessToken(
        authObject: [String: Any],
        file: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let oauth = claudeOAuthDictionary(authObject),
              let access = oauth["accessToken"] as? String, !access.isEmpty else {
            completion(.failure(MeterError.message("Missing Claude access token.")))
            return
        }

        // expiresAt is epoch milliseconds. Refresh five minutes early; tokens
        // without an expiry (long-lived setup tokens) are used as-is.
        guard let expiresAt = number(oauth["expiresAt"]) else {
            completion(.success(access))
            return
        }
        if Date(timeIntervalSince1970: expiresAt / 1000).timeIntervalSinceNow > 5 * 60 {
            completion(.success(access))
            return
        }

        guard let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else {
            completion(.failure(MeterError.message("Access token expired and no refresh token is present.")))
            return
        }

        var request = URLRequest(url: claudeRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("UsageMeterPlus/3", forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": claudeOAuthClientID,
                "scope": claudeOAuthScopes
            ])
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(MeterError.message("No response from Claude OAuth token endpoint.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(MeterError.message(
                    "OAuth refresh failed (HTTP \(http.statusCode)). Re-import/re-login this account."
                )))
                return
            }

            do {
                guard let refreshed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccess = refreshed["access_token"] as? String else {
                    throw MeterError.message("OAuth refresh response had no access_token.")
                }

                var updated = authObject
                var newOAuth = oauth
                newOAuth["accessToken"] = newAccess
                if let newRefresh = refreshed["refresh_token"] as? String, !newRefresh.isEmpty {
                    newOAuth["refreshToken"] = newRefresh
                }
                if let expiresIn = number(refreshed["expires_in"]) {
                    newOAuth["expiresAt"] = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
                }
                if let scope = refreshed["scope"] as? String, !scope.isEmpty {
                    newOAuth["scopes"] = scope.split(separator: " ").map(String.init)
                }
                updated["claudeAiOauth"] = newOAuth

                let output = try JSONSerialization.data(
                    withJSONObject: updated,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try output.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                completion(.success(newAccess))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func fetchClaudeUsage(
        token: String,
        plan: String?,
        completion: @escaping (Result<UsageSnapshot, Error>) -> Void
    ) {
        var request = URLRequest(url: claudeUsageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(claudeOAuthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(MeterError.message("No response from Claude usage endpoint.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(MeterError.message("Usage request failed (HTTP \(http.statusCode)).")))
                return
            }

            do {
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MeterError.message("Unexpected usage response.")
                }
                completion(.success(parseClaudeUsage(root, plan: plan)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

private func parseClaudeUsage(_ root: [String: Any], plan: String?) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: parseClaudeWindow(root["five_hour"], duration: fiveHours),
        weekly: parseClaudeWindow(root["seven_day"], duration: sevenDays),
        plan: plan,
        fetchedAt: Date()
    )
}

private func parseClaudeWindow(_ value: Any?, duration: TimeInterval) -> UsageWindow? {
    // Claude reports utilization as percentage CONSUMED (0...100), and
    // resets_at as ISO 8601 (null until the window has started).
    guard let raw = value as? [String: Any] else { return nil }
    let used = number(raw["utilization"]) ?? 0
    return UsageWindow(
        remaining: min(1, max(0, 1 - used / 100)),
        resetAt: (raw["resets_at"] as? String).flatMap(parseISODate),
        duration: duration
    )
}

private func parseUsage(_ root: [String: Any]) -> UsageSnapshot {
    let rate = (root["rate_limit"] ?? root["rate_limits"]) as? [String: Any]
    var windows: [UsageWindow] = []

    if let rate {
        for key in ["primary_window", "secondary_window", "five_hour", "weekly"] {
            if let raw = rate[key] as? [String: Any], let window = parseWindow(raw) {
                windows.append(window)
            }
        }
    }

    // Do not assume primary == 5h: current responses can place a 7d window in
    // primary_window. Window duration is the source of truth.
    let five = windows.first { abs($0.duration - fiveHours) < 120 }
    let week = windows.first { abs($0.duration - sevenDays) < 120 }
    return UsageSnapshot(
        fiveHour: five,
        weekly: week,
        plan: root["plan_type"] as? String,
        fetchedAt: Date()
    )
}

private func parseWindow(_ raw: [String: Any]) -> UsageWindow? {
    guard let duration = number(raw["limit_window_seconds"] ?? raw["window_seconds"]), duration > 0 else {
        return nil
    }

    // WHAM's used_percent is percentage CONSUMED. The UI is intentionally a
    // percentage REMAINING meter, hence 1 - used.
    let remaining: Double
    if let left = number(raw["percent_left"]) {
        remaining = left / 100
    } else if let used = number(raw["used_percent"] ?? raw["usedPercent"]) {
        remaining = 1 - used / 100
    } else if let utilization = number(raw["utilization"]) {
        let used = utilization > 1 ? utilization / 100 : utilization
        remaining = 1 - used
    } else {
        return nil
    }

    let reset: Date?
    if let seconds = number(raw["reset_at"] ?? raw["resetsAt"]) {
        reset = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
    } else if let milliseconds = number(raw["reset_time_ms"]) {
        reset = Date(timeIntervalSince1970: milliseconds / 1000)
    } else if let after = number(raw["reset_after_seconds"]) {
        reset = Date(timeIntervalSinceNow: after)
    } else if let iso = (raw["reset_at"] ?? raw["resetsAt"]) as? String {
        reset = ISO8601DateFormatter().date(from: iso)
    } else {
        reset = nil
    }

    guard let reset else { return nil }
    return UsageWindow(
        remaining: min(1, max(0, remaining)),
        resetAt: reset,
        duration: duration
    )
}

// MARK: - Palette

private let paletteKeys = ["black", "white", "blue", "green", "orange", "red", "purple"]

private func paletteColor(_ key: String) -> NSColor {
    switch key {
    case "black": return .black
    case "white": return .white
    case "blue": return .systemBlue
    case "green": return .systemGreen
    case "orange": return .systemOrange
    case "red": return .systemRed
    case "purple": return .systemPurple
    default: return .systemBlue
    }
}

private func paletteSwatchImage(_ color: NSColor) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        let rect = NSRect(x: 3, y: 3, width: 12, height: 12)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.labelColor.withAlphaComponent(0.42).setStroke()
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        return true
    }
    image.isTemplate = false
    return image
}

// MARK: - Views

private final class BarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 7)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = min(bounds.height / 2, 3)

        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let width = floor(bounds.width * CGFloat(min(1, max(0, fraction))))
        guard width > 0 else { return }
        barColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

private final class WindowRow: NSView {
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let reset = NSTextField(labelWithString: "")
    private let bar = BarView()

    init(title text: String) {
        super.init(frame: .zero)

        title.stringValue = text
        title.font = .systemFont(ofSize: 11, weight: .medium)

        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.alignment = .right

        reset.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        reset.textColor = .secondaryLabelColor
        reset.alignment = .right

        let header = NSStackView(views: [title, value])
        header.orientation = .horizontal
        header.spacing = 8
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let stack = NSStackView(views: [header, bar, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        reset.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reset.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        update(nil, color: .controlAccentColor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ window: UsageWindow?, color: NSColor) {
        bar.barColor = color
        guard let window else {
            value.stringValue = "—"
            reset.stringValue = "not reported"
            bar.fraction = 0
            return
        }

        value.stringValue = "\(Int((window.remaining * 100).rounded()))% remaining"
        reset.stringValue = window.resetAt.map(resetDescription) ?? "window not started"
        bar.fraction = window.remaining
    }
}

private final class AccountCard: NSView {
    private let accountTitle = NSButton(title: "", target: nil, action: nil)
    private let plan = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let fiveRow = WindowRow(title: "5 hour")
    private let weekRow = WindowRow(title: "Weekly")
    private let error = NSTextField(wrappingLabelWithString: "")

    private var accountIndex = 0
    private var email: String?
    private var showingEmail = false

    var onRemove: (() -> Void)?

    init(index: Int) {
        super.init(frame: .zero)

        accountIndex = index
        accountTitle.title = "Account \(index)"
        accountTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        accountTitle.isBordered = false
        accountTitle.bezelStyle = .inline
        accountTitle.alignment = .left
        accountTitle.target = self
        accountTitle.action = #selector(accountTitleTapped)
        accountTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        accountTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accountTitle.cell?.lineBreakMode = .byTruncatingMiddle

        plan.font = .systemFont(ofSize: 11, weight: .regular)
        plan.textColor = .secondaryLabelColor
        plan.alignment = .right

        removeButton.bezelStyle = .inline
        removeButton.font = .systemFont(ofSize: 12)
        removeButton.toolTip = "Remove account"
        removeButton.target = self
        removeButton.action = #selector(removeTapped)

        error.font = .systemFont(ofSize: 9.5)
        error.textColor = .secondaryLabelColor
        error.maximumNumberOfLines = 2
        error.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [accountTitle, plan, removeButton])
        header.orientation = .horizontal
        header.spacing = 6
        plan.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [header, fiveRow, weekRow, error, separator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        fiveRow.translatesAutoresizingMaskIntoConstraints = false
        weekRow.translatesAutoresizingMaskIntoConstraints = false
        error.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fiveRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            weekRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            error.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            error.heightAnchor.constraint(greaterThanOrEqualToConstant: 11)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(index: Int, account: Account, snapshot: UsageSnapshot?, error message: String?, color: NSColor) {
        accountIndex = index
        email = accountEmail(account)
        if email == nil { showingEmail = false }
        refreshAccountTitle()

        plan.stringValue = planDescription(account.provider, snapshot?.plan)
        fiveRow.update(snapshot?.fiveHour, color: color)
        weekRow.update(snapshot?.weekly, color: color)
        error.stringValue = message ?? ""
    }

    private func refreshAccountTitle() {
        if showingEmail, let email {
            accountTitle.title = email
            accountTitle.toolTip = "Click to hide email"
        } else {
            accountTitle.title = "Account \(accountIndex)"
            accountTitle.toolTip = email == nil ? "Email unavailable in imported credentials" : "Click to show email"
        }
    }

    @objc private func accountTitleTapped() {
        guard email != nil else { return }
        showingEmail.toggle()
        refreshAccountTitle()
    }

    @objc private func removeTapped() { onRemove?() }
}

private final class PanelController: NSViewController {
    private let scroll = NSScrollView()
    private let document = NSView()
    private let accountStack = NSStackView()
    private let refreshButton = NSButton(title: "↻", target: nil, action: nil)
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let paletteButton = NSButton(title: "🎨", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private var scrollHeight: NSLayoutConstraint!
    private var cards: [URL: AccountCard] = [:]
    private var currentPaletteKey = "blue"

    var onRefresh: (() -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((Account) -> Void)?
    var onColorChanged: ((String) -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 180))

        scroll.drawsBackground = false
        // Enable the scroller only when the account content is capped below its
        // requested height. `autohidesScrollers` alone can still reserve/show a
        // scroller for a document view that exactly fills its clip view.
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        accountStack.orientation = .vertical
        accountStack.alignment = .leading
        accountStack.spacing = 9

        document.addSubview(accountStack)
        accountStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accountStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            accountStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            accountStack.topAnchor.constraint(equalTo: document.topAnchor),
            accountStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        scroll.documentView = document

        for button in [refreshButton, addButton, paletteButton, quitButton] {
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11)
        }
        refreshButton.toolTip = "Refresh"
        addButton.toolTip = "Import account"
        paletteButton.toolTip = "Bar color"

        refreshButton.target = self; refreshButton.action = #selector(refreshTapped)
        addButton.target = self; addButton.action = #selector(addTapped)
        paletteButton.target = self; paletteButton.action = #selector(paletteTapped)
        quitButton.target = self; quitButton.action = #selector(quitTapped)

        let spacer = NSView()
        let actions = NSStackView(views: [refreshButton, addButton, paletteButton, spacer, quitButton])
        actions.orientation = .horizontal
        actions.spacing = 10

        let root = NSStackView(views: [scroll, actions])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        view.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false

        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 90)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            actions.widthAnchor.constraint(equalTo: root.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scrollHeight
        ])
    }

    func setAccounts(
        _ accounts: [Account],
        snapshots: [URL: UsageSnapshot],
        errors: [URL: String],
        paletteKey: String
    ) {
        loadViewIfNeeded()
        currentPaletteKey = paletteKey
        cards.removeAll()
        for view in accountStack.arrangedSubviews {
            accountStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if accounts.isEmpty {
            let empty = NSTextField(labelWithString: "No accounts — press +")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            accountStack.addArrangedSubview(empty)
        } else {
            for (offset, account) in accounts.enumerated() {
                let card = AccountCard(index: offset + 1)
                card.onRemove = { [weak self] in self?.onRemove?(account) }
                card.update(
                    index: offset + 1,
                    account: account,
                    snapshot: snapshots[account.file],
                    error: errors[account.file],
                    color: paletteColor(paletteKey)
                )
                accountStack.addArrangedSubview(card)
                card.translatesAutoresizingMaskIntoConstraints = false
                card.widthAnchor.constraint(equalTo: accountStack.widthAnchor).isActive = true
                cards[account.file] = card
            }
        }

        let wanted: CGFloat
        if accounts.isEmpty {
            wanted = 60
        } else {
            // Leave a little breathing room below each account card so its final
            // row never feels clipped against the next account or the actions.
            wanted = CGFloat(accounts.count) * 152 + CGFloat(max(0, accounts.count - 1)) * 9
        }
        let maximumScrollHeight: CGFloat = 660
        scroll.hasVerticalScroller = wanted > maximumScrollHeight
        scrollHeight.constant = min(maximumScrollHeight, wanted)
        preferredContentSize = NSSize(width: 344, height: scrollHeight.constant + 54)
    }

    func update(
        accounts: [Account],
        snapshots: [URL: UsageSnapshot],
        errors: [URL: String],
        paletteKey: String
    ) {
        loadViewIfNeeded()
        guard cards.count == accounts.count else {
            setAccounts(accounts, snapshots: snapshots, errors: errors, paletteKey: paletteKey)
            return
        }

        currentPaletteKey = paletteKey
        for (offset, account) in accounts.enumerated() {
            guard let card = cards[account.file] else {
                setAccounts(accounts, snapshots: snapshots, errors: errors, paletteKey: paletteKey)
                return
            }
            card.update(
                index: offset + 1,
                account: account,
                snapshot: snapshots[account.file],
                error: errors[account.file],
                color: paletteColor(paletteKey)
            )
        }
    }

    @objc private func refreshTapped() { onRefresh?() }
    @objc private func addTapped() { onAdd?() }
    @objc private func quitTapped() { onQuit?() }

    @objc private func paletteTapped() {
        let menu = NSMenu()
        for key in paletteKeys {
            let item = NSMenuItem(title: "", action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = key == currentPaletteKey ? .on : .off
            item.image = paletteSwatchImage(paletteColor(key))
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: paletteButton.bounds.height + 2), in: paletteButton)
    }

    @objc private func colorChosen(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        currentPaletteKey = key
        onColorChanged?(key)
    }
}

// MARK: - App lifecycle

private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let settings = SettingsStore()
    private lazy var store = AccountStore(settings: settings)
    private let client = UsageClient()
    private let panel = PanelController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var snapshots: [URL: UsageSnapshot] = [:]
    private var errors: [URL: String] = [:]
    private var inFlight = Set<URL>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Codex + Claude usage"

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = panel
        popover.delegate = self

        panel.onRefresh = { [weak self] in self?.refreshAll(force: true) }
        panel.onAdd = { [weak self] in self?.addAccounts() }
        panel.onRemove = { [weak self] account in self?.removeAccount(account) }
        panel.onColorChanged = { [weak self] key in
            guard let self else { return }
            self.settings.setBarColor(key)
            self.updateUI()
        }
        panel.onQuit = { NSApp.terminate(nil) }

        updateUI(rebuild: true)
        scheduleTimer(open: false)
        refreshAll(force: true)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(woke),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            scheduleTimer(open: true)
            refreshAll(force: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        scheduleTimer(open: false)
    }

    @objc private func woke() {
        refreshAll(force: true)
    }

    @objc private func timerFired() {
        // This updates countdown text/ETA without any animation or display loop.
        updateUI()
        refreshAll(force: false)
    }

    private func refreshAll(force: Bool) {
        guard !store.accounts.isEmpty else {
            updateUI()
            return
        }

        let desiredAge: TimeInterval = popover.isShown ? 60 : 300
        for account in store.accounts {
            if inFlight.contains(account.file) { continue }
            if !force, let cached = snapshots[account.file],
               Date().timeIntervalSince(cached.fetchedAt) < desiredAge * 0.90 {
                continue
            }

            inFlight.insert(account.file)
            client.fetch(account: account) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight.remove(account.file)

                    // Ignore a response if the account was removed while fetching.
                    guard self.store.accounts.contains(where: { $0.file == account.file }) else { return }

                    switch result {
                    case .success(let snapshot):
                        self.snapshots[account.file] = snapshot
                        self.errors.removeValue(forKey: account.file)
                    case .failure(let error):
                        self.errors[account.file] = error.localizedDescription
                    }
                    self.updateUI()
                }
            }
        }
    }

    private func scheduleTimer(open: Bool) {
        timer?.invalidate()
        let interval: TimeInterval = open ? 60 : 300
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = open ? 6 : 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateUI(rebuild: Bool = false) {
        let key = settings.data.barColor
        if rebuild {
            panel.setAccounts(store.accounts, snapshots: snapshots, errors: errors, paletteKey: key)
        } else {
            panel.update(accounts: store.accounts, snapshots: snapshots, errors: errors, paletteKey: key)
        }
        updateStatusItem()
    }

    private func addAccounts() {
        let open = NSOpenPanel()
        open.title = "Import Codex or Claude credentials"
        open.message = "Select one or more Codex auth.json or Claude Code credentials JSON files."
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false

        open.begin { [weak self] response in
            guard response == .OK, let self else { return }
            var lastError: String?
            for source in open.urls {
                do {
                    try self.store.importAuth(from: source)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            self.store.reload()
            if let lastError, let last = self.store.accounts.last {
                self.errors[last.file] = lastError
            }
            self.updateUI(rebuild: true)
            self.refreshAll(force: true)
        }
    }

    private func removeAccount(_ account: Account) {
        guard let index = store.accounts.firstIndex(of: account) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove Account \(index + 1)?"
        alert.informativeText = "Only UsageMeterPlus's imported credential copy is deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.remove(account)
            snapshots.removeValue(forKey: account.file)
            errors.removeValue(forKey: account.file)
            inFlight.remove(account.file)
            updateUI(rebuild: true)
        } catch {
            errors[account.file] = error.localizedDescription
            updateUI()
        }
    }

    private func updateStatusItem() {
        let items = store.accounts.map { account in
            let snapshot = snapshots[account.file]
            return MiniBarUsage(hourly: snapshot?.fiveHour, weekly: snapshot?.weekly)
        }
        let image = statusImage(items: items, color: paletteColor(settings.data.barColor))
        statusItem.button?.image = image
        statusItem.button?.toolTip = store.accounts.isEmpty
            ? "Codex + Claude usage — click to add an account"
            : "Codex + Claude usage — \(store.accounts.count) account\(store.accounts.count == 1 ? "" : "s")"
    }
}

// MARK: - Formatting + icon

private func planDescription(_ provider: Provider, _ raw: String?) -> String {
    let name = provider.displayName
    guard let raw, !raw.isEmpty else { return name }
    let words = raw
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(separator: " ")
        .map { String($0).capitalized }
        .joined(separator: " ")
    return "\(name) \(words)"
}

private func resetDescription(_ date: Date) -> String {
    let remaining = detailedDuration(max(0, date.timeIntervalSinceNow))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return "resets in \(remaining) · at \(formatter.string(from: date))"
}

private func detailedDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(ceil(seconds / 60)))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60

    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

private func statusETA(_ seconds: TimeInterval) -> String {
    let seconds = max(0, seconds)
    if seconds >= 90 * 60 {
        return String(format: "%.1fh", seconds / 3600)
    }
    return "\(max(0, Int(ceil(seconds / 60))))m"
}

private func statusDaysETA(_ seconds: TimeInterval) -> String {
    return String(format: "%.1fd", max(0, seconds) / (24 * 60 * 60))
}

private struct MiniBarUsage {
    let hourly: UsageWindow?
    let weekly: UsageWindow?

    var weeklyIsExhausted: Bool {
        guard let weekly else { return false }
        return weekly.remaining <= 0
    }
}

private func statusImage(items: [MiniBarUsage], color: NSColor) -> NSImage {
    if items.isEmpty {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            ("U+" as NSString).draw(at: NSPoint(x: 3, y: 3), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    let barWidth: CGFloat = 22
    let barHeight: CGFloat = 6
    let barToETA: CGFloat = 4
    let accountGap: CGFloat = 7
    let etaAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.labelColor
    ]

    let groups: [(window: UsageWindow?, weeklyIsExhausted: Bool, eta: NSString, width: CGFloat)] = items.map { item in
        let eta: NSString
        if item.weeklyIsExhausted, let reset = item.weekly?.resetAt {
            eta = statusDaysETA(reset.timeIntervalSinceNow) as NSString
        } else if let reset = item.hourly?.resetAt {
            eta = statusETA(reset.timeIntervalSinceNow) as NSString
        } else {
            eta = "—"
        }
        let etaWidth = ceil(eta.size(withAttributes: etaAttributes).width)
        return (item.hourly, item.weeklyIsExhausted, eta, barWidth + barToETA + etaWidth)
    }

    let width = groups.reduce(CGFloat(0)) { $0 + $1.width }
        + CGFloat(max(0, groups.count - 1)) * accountGap
    let size = NSSize(width: width, height: 18)

    let image = NSImage(size: size, flipped: false) { _ in
        var x: CGFloat = 0

        for group in groups {
            let bar = NSRect(x: x, y: 6, width: barWidth, height: barHeight)
            let barOpacity: CGFloat = group.weeklyIsExhausted ? 0.22 : 1
            NSColor.labelColor.withAlphaComponent(0.14 * barOpacity).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()

            if let window = group.window {
                let fillWidth = floor(bar.width * CGFloat(window.remaining))
                if fillWidth > 0 {
                    color.withAlphaComponent(barOpacity).setFill()
                    NSBezierPath(
                        roundedRect: NSRect(x: bar.minX, y: bar.minY, width: fillWidth, height: bar.height),
                        xRadius: 2,
                        yRadius: 2
                    ).fill()
                }
            }

            group.eta.draw(
                at: NSPoint(x: x + barWidth + barToETA, y: 3.4),
                withAttributes: etaAttributes
            )
            x += group.width + accountGap
        }
        return true
    }
    image.isTemplate = false
    return image
}

// MARK: - Helpers

private func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

private func jsonObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MeterError.message("Invalid JSON in \(url.lastPathComponent).")
    }
    return object
}

private func tokenDictionary(_ root: [String: Any]) -> [String: Any]? {
    root["tokens"] as? [String: Any]
}

private func claudeOAuthDictionary(_ root: [String: Any]) -> [String: Any]? {
    root["claudeAiOauth"] as? [String: Any]
}

private func providerOf(_ root: [String: Any]) -> Provider? {
    if tokenDictionary(root) != nil { return .codex }
    if claudeOAuthDictionary(root) != nil { return .claude }
    return nil
}

private func parseISODate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    // Fall back to dropping sub-second precision (Claude sends microseconds).
    formatter.formatOptions = [.withInternetDateTime]
    let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return formatter.date(from: trimmed)
}

private func accountEmail(_ account: Account) -> String? {
    guard let root = try? jsonObject(account.file) else { return nil }
    if let email = root["email"] as? String, !email.isEmpty { return email }
    if let email = claudeOAuthDictionary(root)?["email"] as? String, !email.isEmpty { return email }

    guard let tokens = tokenDictionary(root) else { return nil }
    if let email = tokens["email"] as? String, !email.isEmpty { return email }

    for key in ["id_token", "access_token"] {
        guard let token = tokens[key] as? String,
              let payload = jwtPayload(token) else { continue }

        if let email = payload["email"] as? String, !email.isEmpty {
            return email
        }

        // Some OpenAI token variants keep profile claims under a namespaced object.
        for value in payload.values {
            if let dictionary = value as? [String: Any],
               let email = dictionary["email"] as? String,
               !email.isEmpty {
                return email
            }
        }
    }
    return nil
}

private func jwtExpiration(_ token: String) -> Date? {
    guard let payload = jwtPayload(token), let expiration = number(payload["exp"]) else { return nil }
    return Date(timeIntervalSince1970: expiration)
}

private func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var text = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text.append("=") }
    guard let data = Data(base64Encoded: text),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object
}

private func formBody(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let encoded = fields.map { key, value in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
    return encoded.data(using: .utf8) ?? Data()
}

// MARK: - Process entry point

let app = NSApplication.shared
private let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
