import Foundation
import Security

// MARK: - Paths

public enum AppPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UsageTracker", isDirectory: true)
    }

    public static var stateFile: URL {
        applicationSupport.appendingPathComponent("state.json")
    }
}

public enum OpenCodePaths {
    public static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    public static var authFile: URL {
        dataDirectory.appendingPathComponent("auth.json")
    }

    public static var databaseFile: URL {
        dataDirectory.appendingPathComponent("opencode.db")
    }
}

public enum ClaudePaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    public static var statsCacheFile: URL {
        directory.appendingPathComponent("stats-cache.json")
    }

    public static var projectsDirectory: URL {
        directory.appendingPathComponent("projects", isDirectory: true)
    }

    public static var credentialsFile: URL {
        directory.appendingPathComponent(".credentials.json")
    }
}

// MARK: - Keychain

public enum KeychainStore {
    public static let service = "dev.kemel.usagetracker"

    public static func read(account: String) -> String? {
        read(service: service, account: account)
    }

    /// Lee un elemento genérico de cualquier servicio del Keychain.
    ///
    /// Se usa para credenciales que guardan otras apps, como la clave del
    /// proxy de LiteLLM que guarda Claude Usage Tracker.
    public static func read(service: String, account: String) -> String? {
        readWithStatus(service: service, account: account).value
    }

    /// Igual que `read(service:account:)`, pero devuelve también el estado, para
    /// poder distinguir "no existe" de "el usuario ha denegado el acceso".
    public static func readWithStatus(service: String, account: String) -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    public static func save(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.status(addStatus)
        }
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return "Keychain: \(message)"
                }
                return "Keychain: error \(status)"
            }
        }
    }
}

public enum ClaudeKeychain {
    public static func readCredentials() -> ClaudeCredentials? {
        if let data = readKeychainData(),
           let credentials = parse(data: data) {
            return credentials
        }

        if let data = try? Data(contentsOf: ClaudePaths.credentialsFile),
           let credentials = parse(data: data) {
            return credentials
        }

        if let output = readWithSecurityCLI(),
           let data = output.data(using: .utf8),
           let credentials = parse(data: data) {
            return credentials
        }

        return nil
    }

    private static func readKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func readWithSecurityCLI() -> String? {
        guard let security = ProcessRunner.findExecutable("security") else { return nil }
        guard let output = try? ProcessRunner.run(security, [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w"
        ]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parse(data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            return nil
        }

        var expiresAt: Date?
        if let number = oauth["expiresAt"] as? NSNumber {
            let raw = number.doubleValue
            let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
            expiresAt = Date(timeIntervalSince1970: seconds)
        }

        return ClaudeCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

// MARK: - OpenCode auth

public enum OpenCodeAuth {
    public static func apiKey() -> String? {
        guard let data = try? Data(contentsOf: OpenCodePaths.authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - GitHub CLI

public enum GitHubCLI {
    public static func token() -> String? {
        guard let gh = ProcessRunner.findExecutable("gh") else { return nil }
        guard let output = try? ProcessRunner.run(gh, ["auth", "token"]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - LiteLLM

/// Detecta la clave del proxy LiteLLM.
///
/// Se buscan tres fuentes, en este orden:
/// 1. La configuración de Claude Code, si apunta al proxy LiteLLM.
/// 2. Un `export ANTHROPIC_AUTH_TOKEN=` literal en el perfil del shell.
/// 3. El Keychain de Claude Usage Tracker, que guarda la misma clave.
public enum LiteLLMKeyLocator {
    private static let trackerService = "com.claudeusage.tracker.litellm"
    private static let trackerAccount = "litellm-api-key"
    private static let shellProfiles = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile"]
    private static let exportPrefix = "export ANTHROPIC_AUTH_TOKEN="

    /// La clave detectada se conserva solo en memoria durante esta ejecución.
    /// Volver a leer un item de otra app en cada refresco puede reabrir el diálogo
    /// de autorización del Keychain, especialmente en builds firmadas ad-hoc.
    private static let stateLock = NSLock()
    private enum TrackerKeychainResult {
        case found(String)
        case missing
        case denied
    }
    private static var trackerKeychainResults: [String: TrackerKeychainResult] = [:]

    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let proxyHost = EndpointConfiguration.liteLLMProxyBaseURL?.host else { return nil }
        if let key = keyFromSettings(home: home, expectedProxyHost: proxyHost) { return key }
        for name in shellProfiles {
            if let key = keyFromShellProfile(home.appendingPathComponent(name), expectedProxyHost: proxyHost) {
                return key
            }
        }
        return keyFromTrackerKeychain(proxyHost: proxyHost)
    }

    /// La clave que guarda Claude Usage Tracker. Es la fuente más probable:
    /// esa app ya seauthenticó en el proxy y guardó la clave allí.
    private static func keyFromTrackerKeychain(proxyHost: String) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let cached = trackerKeychainResults[proxyHost] {
            switch cached {
            case .found(let value): return value
            case .missing, .denied: return nil
            }
        }

        let result = KeychainStore.readWithStatus(service: trackerService, account: trackerAccount)
        if result.status == errSecAuthFailed || result.status == errSecInteractionNotAllowed {
            trackerKeychainResults[proxyHost] = .denied
            return nil
        }
        if result.status == errSecItemNotFound {
            trackerKeychainResults[proxyHost] = .missing
            return nil
        }
        guard result.status == errSecSuccess,
              let rawValue = result.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = usable(rawValue) else {
            return nil
        }
        trackerKeychainResults[proxyHost] = .found(value)
        return value
    }

    /// `~/.claude/settings.json` y los perfiles `~/.claude-*`.
    public static func keyFromSettings(home: URL, expectedProxyHost: String? = nil) -> String? {
        var directories: [URL] = [home.appendingPathComponent(".claude")]
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        directories += profiles
            .filter { $0.hasPrefix(".claude-") }
            .sorted()
            .map { home.appendingPathComponent($0) }

        for directory in directories {
            guard let key = key(
                fromSettings: directory.appendingPathComponent("settings.json"),
                expectedProxyHost: expectedProxyHost ?? EndpointConfiguration.liteLLMProxyBaseURL?.host
            ) else {
                continue
            }
            return key
        }
        return nil
    }

    private static func key(fromSettings url: URL, expectedProxyHost: String?) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let baseURL = env["ANTHROPIC_BASE_URL"] as? String,
              let expectedProxyHost,
              URL(string: baseURL)?.host == expectedProxyHost else { return nil }
        let key = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String)
        return key.flatMap(usable)
    }

    /// Solo valores literales: se descartan los exports construidos con
    /// variables o con sustitución de comandos.
    public static func keyFromShellProfile(_ url: URL, expectedProxyHost: String? = nil) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let expectedProxyHost = expectedProxyHost ?? EndpointConfiguration.liteLLMProxyBaseURL?.host,
              text.contains(expectedProxyHost) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(exportPrefix) else { continue }
            var value = String(trimmed.dropFirst(exportPrefix.count))
            // El valor acaba en el primer separador: `; export …`, `&& …`, ` # comentario`.
            if let end = value.firstIndex(where: { ";&| \t#".contains($0) }) { value = String(value[..<end]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard !value.contains("$"), !value.contains("`"), let key = usable(value) else { continue }
            return key
        }
        return nil
    }

    /// Las claves directas de Anthropic nunca se envían al proxy LiteLLM.
    private static func usable(_ key: String) -> String? {
        key.isEmpty || key.hasPrefix("sk-ant-") ? nil : key
    }
}

// MARK: - Process runner

public enum ProcessRunner {
    public enum ProcessError: LocalizedError {
        case notFound(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let name): return "No se encontró el ejecutable \(name)."
            case .failed(let message): return message
            }
        }
    }

    public static func findExecutable(_ name: String) -> String? {
        let fileManager = FileManager.default

        if name.contains("/") {
            return fileManager.isExecutableFile(atPath: name) ? name : nil
        }

        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let candidate = "\(component)/\(name)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    public static func run(_ executable: String, _ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.notFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let error = String(data: errorData, encoding: .utf8) ?? ""
            throw ProcessError.failed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }
}

// MARK: - Credentials

public enum CredentialResolver {
    /// Resuelve solo las credenciales de los proveedores indicados. Los demás
    /// quedan marcados como desactivados y no se toca el Keychain ni sus
    /// herramientas externas. Así, desactivar Claude evita el aviso de macOS
    /// cada vez que la app refresca.
    public static func resolve(for providers: Set<ProviderID> = Set(ProviderID.allCases)) -> ResolvedCredentials {
        var statuses = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { ($0, CredentialStatus.disabled) }
        )

        var openCodeKey: String?
        if providers.contains(.opencodeGo) {
            let manualOpenCode = KeychainStore.read(account: ProviderID.opencodeGo.rawValue)
            let detectedOpenCode = OpenCodeAuth.apiKey()
            openCodeKey = manualOpenCode ?? detectedOpenCode
            statuses[.opencodeGo] = manualOpenCode != nil ? .manual : (detectedOpenCode != nil ? .detected : .missing)
        }

        var copilotToken: String?
        if providers.contains(.copilot) {
            let manualCopilot = KeychainStore.read(account: ProviderID.copilot.rawValue)
            let detectedCopilot = GitHubCLI.token()
            copilotToken = manualCopilot ?? detectedCopilot
            statuses[.copilot] = manualCopilot != nil ? .manual : (detectedCopilot != nil ? .detected : .missing)
        }

        var claude: ClaudeCredentials?
        if providers.contains(.claude) {
            let manualClaude = KeychainStore.read(account: ProviderID.claude.rawValue)
            if let manualClaude, !manualClaude.isEmpty {
                claude = ClaudeCredentials(accessToken: manualClaude)
                statuses[.claude] = .manual
            } else if let detected = ClaudeKeychain.readCredentials() {
                claude = detected
                statuses[.claude] = detected.isExpired ? .expired : .detected
            } else {
                statuses[.claude] = .missing
            }
        }

        var liteLLMKey: String?
        if providers.contains(.liteLLM) {
            let manualLiteLLM = KeychainStore.read(account: ProviderID.liteLLM.rawValue)
            let legacyManual = manualLiteLLM == nil
                ? KeychainStore.read(account: ProviderID.legacyLiteLLMIdentifier)
                : nil
            if manualLiteLLM == nil, let legacyManual {
                if (try? KeychainStore.save(account: ProviderID.liteLLM.rawValue, value: legacyManual)) != nil {
                    KeychainStore.delete(account: ProviderID.legacyLiteLLMIdentifier)
                }
            }
            let savedManual = manualLiteLLM ?? legacyManual
            if let savedManual, !savedManual.isEmpty {
                liteLLMKey = savedManual
                statuses[.liteLLM] = .manual
            } else {
                liteLLMKey = LiteLLMKeyLocator.detect()
                statuses[.liteLLM] = liteLLMKey != nil ? .detected : .missing
            }
        }

        return ResolvedCredentials(
            openCodeKey: openCodeKey,
            copilotToken: copilotToken,
            claude: claude,
            liteLLMKey: liteLLMKey,
            statuses: statuses
        )
    }
}
