import Foundation

/// Private deployment configuration. Production URLs are supplied by the local
/// ignored plist or build environment; they are not committed with the source.
public enum EndpointConfiguration {
    public static var liteLLMProxyBaseURL: URL? {
        configuredURL(
            infoKey: "LiteLLMProxyBaseURL",
            environmentKey: "USAGE_TRACKER_LITELLM_PROXY_BASE_URL"
        )
    }

    /// Root of the corporate account portal used to establish the IAP session.
    public static var accountPortalBaseURL: URL? {
        configuredURL(
            infoKey: "LiteLLMAccountPortalBaseURL",
            environmentKey: "USAGE_TRACKER_ACCOUNT_PORTAL_BASE_URL"
        )
    }

    public static var accountAPIBaseURL: URL? {
        accountPortalBaseURL?.appendingPathComponent("api/v1/", isDirectory: true)
    }

    private static func configuredURL(infoKey: String, environmentKey: String) -> URL? {
        let environmentValue = ProcessInfo.processInfo.environment[environmentKey]
        let bundledValue = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
        let localValue = localConfiguration?[infoKey] as? String
        guard let value = environmentValue ?? bundledValue ?? localValue,
              var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil else {
            return nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    private static let localConfiguration: [String: Any]? = {
        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources/Endpoints.private.plist"),
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("Resources/Endpoints.private.plist")
        ]
        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let dictionary = plist as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }()
}
