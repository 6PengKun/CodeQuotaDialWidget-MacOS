import CFNetwork
import Foundation
import Testing

@testable import QuotaProcessSupport

@Test func manualOverrideWinsOverSystemProxy() {
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [httpProxy(host: "system.proxy", port: 7897)] }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: "  http://manual.proxy:8080  ")

    #expect(proxy == "http://manual.proxy:8080")
}

@Test func directSystemProxyReturnsNil() {
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [directProxy()] }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == nil)
}

@Test func httpProxyBuildsCurlProxyURL() {
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [httpProxy(host: "127.0.0.1", port: 7897)] }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == "http://127.0.0.1:7897")
}

@Test func httpsProxyBuildsCurlProxyURL() {
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [httpsProxy(host: "secure.proxy", port: 8443)] }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == "http://secure.proxy:8443")
}

@Test func socksProxyBuildsCurlProxyURL() {
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [socksProxy(host: "socks.proxy", port: 1080)] }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == "socks5h://socks.proxy:1080")
}

@Test func pacScriptResolvesToConcreteProxy() {
    let pacScript = "function FindProxyForURL(url, host) { return 'SOCKS5 socks.proxy:1080'; }"
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [pacScriptProxy(script: pacScript)] },
        proxiesForPACScript: { script, _ in
            #expect(script == pacScript)
            return [socksProxy(host: "socks.proxy", port: 1080)]
        }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == "socks5h://socks.proxy:1080")
}

@Test func pacURLResolvesToHTTPProxy() {
    let pacURL = URL(string: "https://proxy.example/proxy.pac")!
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [pacURLProxy(url: pacURL)] },
        proxiesForPACURL: { url, _, _ in
            #expect(url == pacURL)
            return [httpProxy(host: "pac.proxy", port: 9000)]
        }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == "http://pac.proxy:9000")
}

@Test func pacURLResolvesToSOCKSProxy() {
    let pacURL = URL(string: "https://proxy.example/proxy.pac")!
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [pacURLProxy(url: pacURL)] },
        proxiesForPACURL: { url, _, _ in
            #expect(url == pacURL)
            return [socksProxy(host: "pac.socks", port: 1080)]
        }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == "socks5h://pac.socks:1080")
}

@Test func pacURLCanResolveToDirect() {
    let pacURL = URL(string: "https://proxy.example/proxy.pac")!
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [pacURLProxy(url: pacURL)] },
        proxiesForPACURL: { url, _, _ in
            #expect(url == pacURL)
            return [directProxy()]
        }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == nil)
}

@Test func pacURLFailureFallsBackToLaterProxyCandidate() {
    let pacURL = URL(string: "https://proxy.example/proxy.pac")!
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [pacURLProxy(url: pacURL), httpProxy(host: "fallback.proxy", port: 8080)] },
        proxiesForPACURL: { url, _, _ in
            #expect(url == pacURL)
            return nil
        }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == "http://fallback.proxy:8080")
}

@Test func pacURLTimeoutFallsBackWithoutHanging() {
    let pacURL = URL(string: "https://proxy.example/proxy.pac")!
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [pacURLProxy(url: pacURL)] },
        proxiesForPACURL: { url, _, timeout in
            #expect(url == pacURL)
            #expect(timeout == 0.01)
            return nil
        },
        pacURLTimeout: 0.01
    )

    let start = Date()
    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == nil)
    #expect(Date().timeIntervalSince(start) < 0.5)
}

@Test func malformedProxyDictionaryFallsBackToDirect() {
    let resolver = makeResolver(
        proxiesForURL: { _, _ in [[proxyTypeKey: kCFProxyTypeHTTP as String, proxyHostKey: "broken.proxy"]] }
    )

    let proxy = resolver.curlProxy(for: "https://example.com/quota", manualOverride: nil)

    #expect(proxy == nil)
}

private func makeResolver(
    proxiesForURL: @escaping @Sendable (URL, ProxyDictionary) -> [ProxyDictionary],
    proxiesForPACURL: @escaping @Sendable (URL, URL, TimeInterval) -> [ProxyDictionary]? = { _, _, _ in nil },
    proxiesForPACScript: @escaping @Sendable (String, URL) -> [ProxyDictionary] = { _, _ in [] },
    pacURLTimeout: TimeInterval = 5
) -> Resolver {
    Resolver(
        environment: .init(
            systemProxySettings: { [:] },
            proxiesForURL: proxiesForURL,
            proxiesForPACURL: proxiesForPACURL,
            proxiesForPACScript: proxiesForPACScript
        ),
        pacURLTimeout: pacURLTimeout
    )
}

private let proxyTypeKey = kCFProxyTypeKey as String
private let proxyHostKey = kCFProxyHostNameKey as String
private let proxyPortKey = kCFProxyPortNumberKey as String
private let pacURLKey = kCFProxyAutoConfigurationURLKey as String
private let pacScriptKey = kCFProxyAutoConfigurationJavaScriptKey as String

private func directProxy() -> ProxyDictionary {
    [proxyTypeKey: kCFProxyTypeNone as String]
}

private func httpProxy(host: String, port: Int) -> ProxyDictionary {
    [
        proxyTypeKey: kCFProxyTypeHTTP as String,
        proxyHostKey: host,
        proxyPortKey: port
    ]
}

private func httpsProxy(host: String, port: Int) -> ProxyDictionary {
    [
        proxyTypeKey: kCFProxyTypeHTTPS as String,
        proxyHostKey: host,
        proxyPortKey: port
    ]
}

private func socksProxy(host: String, port: Int) -> ProxyDictionary {
    [
        proxyTypeKey: kCFProxyTypeSOCKS as String,
        proxyHostKey: host,
        proxyPortKey: port
    ]
}

private func pacURLProxy(url: URL) -> ProxyDictionary {
    [
        proxyTypeKey: kCFProxyTypeAutoConfigurationURL as String,
        pacURLKey: url
    ]
}

private func pacScriptProxy(script: String) -> ProxyDictionary {
    [
        proxyTypeKey: kCFProxyTypeAutoConfigurationJavaScript as String,
        pacScriptKey: script
    ]
}
