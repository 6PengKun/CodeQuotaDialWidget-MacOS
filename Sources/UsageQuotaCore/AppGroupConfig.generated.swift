import Foundation

public enum UsageQuotaAppGroup {
    public static let identifier = "W6K5K7AHZ9.group.local.usage-quota-monitor"
}

public enum UsageRemoteConfig {
    /// SSH hosts for joint multi-end statistics. Empty = local only.
    public static let remoteHosts: [String] = ["10.160.4.89"]
}
