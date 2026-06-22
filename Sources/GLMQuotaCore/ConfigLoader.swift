import Foundation

public struct GLMConfig: Sendable {
    public var apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public static func load() throws -> GLMConfig {
        // Single source: the API key set in the GLM panel (shared runtime config).
        guard let key = GLMQuotaApiKeyConfig.apiKey else {
            throw GLMConfigError.notConfigured
        }
        return GLMConfig(apiKey: key)
    }

    /// The resolved API key, or `nil` if none is set. Lets the app show a
    /// "已设置/未设置" state without surfacing the key itself.
    public static func resolvedApiKey() -> String? {
        GLMQuotaApiKeyConfig.apiKey
    }
}

public enum GLMConfigError: Error, LocalizedError {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "未配置 GLM API Key，请在 GLM 组件页面填写"
        }
    }
}
