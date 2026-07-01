@preconcurrency import CFNetwork
import Foundation
import QuotaProxyCFSupport

public enum QuotaProxyResolver {
    public static func curlProxy(for targetURL: String, manualOverride: String?) -> String? {
        Resolver(environment: .live).curlProxy(for: targetURL, manualOverride: manualOverride)
    }
}

typealias ProxyDictionary = [AnyHashable: Any]

struct Resolver {
    struct Environment: @unchecked Sendable {
        var systemProxySettings: () -> ProxyDictionary?
        var proxiesForURL: (URL, ProxyDictionary) -> [ProxyDictionary]
        var proxiesForPACURL: (URL, URL, TimeInterval) -> [ProxyDictionary]?
        var proxiesForPACScript: (String, URL) -> [ProxyDictionary]

        static let live = Environment(
            systemProxySettings: {
                guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
                    return nil
                }
                return settings as? ProxyDictionary
            },
            proxiesForURL: { targetURL, settings in
                let proxies = CFNetworkCopyProxiesForURL(targetURL as CFURL, settings as CFDictionary)
                    .takeRetainedValue()
                return proxies as? [ProxyDictionary] ?? []
            },
            proxiesForPACURL: { pacURL, targetURL, timeout in
                guard let proxies = QuotaCopyProxiesForAutoConfigurationURL(
                    pacURL as CFURL,
                    targetURL as CFURL,
                    timeout
                ) else {
                    return nil
                }
                return proxies as? [ProxyDictionary] ?? []
            },
            proxiesForPACScript: { script, targetURL in
                var error: Unmanaged<CFError>?
                guard let proxies = CFNetworkCopyProxiesForAutoConfigurationScript(
                    script as CFString,
                    targetURL as CFURL,
                    &error
                )?.takeRetainedValue() else {
                    return []
                }
                return proxies as? [ProxyDictionary] ?? []
            }
        )
    }

    private enum Result {
        case proxy(String)
        case direct
        case unresolved
    }

    private let environment: Environment
    private let pacURLTimeout: TimeInterval

    init(environment: Environment, pacURLTimeout: TimeInterval = 5) {
        self.environment = environment
        self.pacURLTimeout = pacURLTimeout
    }

    func curlProxy(for targetURL: String, manualOverride: String?) -> String? {
        if let manualOverride = Self.normalized(manualOverride) {
            return manualOverride
        }

        guard
            let url = URL(string: targetURL),
            let settings = environment.systemProxySettings()
        else {
            return nil
        }

        switch resolve(url: url, proxies: environment.proxiesForURL(url, settings), depth: 0) {
        case .proxy(let proxy):
            return proxy
        case .direct, .unresolved:
            return nil
        }
    }

    private func resolve(url: URL, proxies: [ProxyDictionary], depth: Int) -> Result {
        guard depth < 4 else {
            return .unresolved
        }

        for proxy in proxies {
            switch proxyType(in: proxy) {
            case .http:
                if let proxyURL = curlProxyURL(scheme: "http", proxy: proxy) {
                    return .proxy(proxyURL)
                }
            case .https:
                if let proxyURL = curlProxyURL(scheme: "http", proxy: proxy) {
                    return .proxy(proxyURL)
                }
            case .socks:
                if let proxyURL = curlProxyURL(scheme: "socks5h", proxy: proxy) {
                    return .proxy(proxyURL)
                }
            case .direct:
                return .direct
            case .pacScript:
                guard let script = proxy[ProxyKey.pacScript] as? String else {
                    continue
                }
                let nested = environment.proxiesForPACScript(script, url)
                let resolved = resolve(url: url, proxies: nested, depth: depth + 1)
                switch resolved {
                case .unresolved:
                    continue
                case .direct, .proxy:
                    return resolved
                }
            case .pacURL:
                guard let pacURL = pacURL(from: proxy) else {
                    continue
                }
                guard let nested = environment.proxiesForPACURL(pacURL, url, pacURLTimeout) else {
                    continue
                }
                let resolved = resolve(url: url, proxies: nested, depth: depth + 1)
                switch resolved {
                case .unresolved:
                    continue
                case .direct, .proxy:
                    return resolved
                }
            case .unsupported:
                continue
            }
        }

        return .unresolved
    }

    private func curlProxyURL(scheme: String, proxy: ProxyDictionary) -> String? {
        guard
            let host = Self.normalized(proxy[ProxyKey.host] as? String),
            let port = port(from: proxy[ProxyKey.port])
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        if let username = Self.normalized(proxy[ProxyKey.username] as? String) {
            components.user = username
        }
        if let password = Self.normalized(proxy[ProxyKey.password] as? String) {
            components.password = password
        }
        return components.string
    }

    private func proxyType(in proxy: ProxyDictionary) -> ProxyKind {
        guard let value = proxy[ProxyKey.type] as? String else {
            return .unsupported
        }
        switch value {
        case ProxyValue.http:
            return .http
        case ProxyValue.https:
            return .https
        case ProxyValue.socks:
            return .socks
        case ProxyValue.direct:
            return .direct
        case ProxyValue.pacURL:
            return .pacURL
        case ProxyValue.pacScript:
            return .pacScript
        default:
            return .unsupported
        }
    }

    private func pacURL(from proxy: ProxyDictionary) -> URL? {
        if let url = proxy[ProxyKey.pacURL] as? URL {
            return url
        }
        if let string = proxy[ProxyKey.pacURL] as? String {
            return URL(string: string)
        }
        return nil
    }

    private func port(from rawValue: Any?) -> Int? {
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        if let string = rawValue as? String {
            return Int(string)
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum ProxyKind {
    case http
    case https
    case socks
    case direct
    case pacURL
    case pacScript
    case unsupported
}

private enum ProxyKey {
    static let type = kCFProxyTypeKey as String
    static let host = kCFProxyHostNameKey as String
    static let port = kCFProxyPortNumberKey as String
    static let username = kCFProxyUsernameKey as String
    static let password = kCFProxyPasswordKey as String
    static let pacURL = kCFProxyAutoConfigurationURLKey as String
    static let pacScript = kCFProxyAutoConfigurationJavaScriptKey as String
}

private enum ProxyValue {
    static let http = kCFProxyTypeHTTP as String
    static let https = kCFProxyTypeHTTPS as String
    static let socks = kCFProxyTypeSOCKS as String
    static let direct = kCFProxyTypeNone as String
    static let pacURL = kCFProxyTypeAutoConfigurationURL as String
    static let pacScript = kCFProxyTypeAutoConfigurationJavaScript as String
}
