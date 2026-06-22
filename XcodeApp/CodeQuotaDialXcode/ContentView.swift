import SwiftUI

struct ContentView: View {
    @State private var selection: DashboardSection = .codex

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("额度监控") {
                ForEach(DashboardSection.quotaCases) { section in
                    sidebarRow(section).tag(section)
                }
            }

            Section("用量统计") {
                sidebarRow(.usage).tag(DashboardSection.usage)
            }

            Section("其他") {
                sidebarRow(.settings).tag(DashboardSection.settings)
            }
        }
        .listStyle(.sidebar)
        .headerProminence(.increased)
        .environment(\.defaultMinListRowHeight, 34)
        .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Code Quota Dial")
                .font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func sidebarRow(_ section: DashboardSection) -> some View {
        HStack(spacing: 10) {
            SectionIcon(section: section)
            Text(section.title)
                .font(.body)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .codex:       CodexQuotaPanelView()
        case .claude:      ClaudeQuotaPanelView()
        case .glm:         GLMQuotaPanelView()
        case .antigravity: AntigravityQuotaPanelView()
        case .usage:       UsagePanelView()
        case .settings:    SettingsPanelView()
        }
    }
}

/// Sidebar leading icon: the provider's bundled app icon (in Assets.xcassets) for
/// Codex / Claude / GLM / Antigravity, or a tinted SF Symbol for the rest.
private struct SectionIcon: View {
    let section: DashboardSection

    var body: some View {
        if let asset = section.iconAsset {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: section.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(section.accent)
                .frame(width: 22, height: 22)
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case codex
    case claude
    case glm
    case antigravity
    case usage
    case settings

    var id: String { rawValue }

    static let quotaCases: [DashboardSection] = [.codex, .claude, .glm, .antigravity]

    var title: String {
        switch self {
        case .codex:       return "Codex"
        case .claude:      return "Claude"
        case .glm:         return "GLM"
        case .antigravity: return "Antigravity"
        case .usage:       return "消耗统计"
        case .settings:    return "设置"
        }
    }

    /// Asset-catalog image name for the provider's app icon, or `nil` to use the
    /// SF Symbol. The PNGs live in Assets.xcassets keyed by the case rawValue.
    var iconAsset: String? {
        switch self {
        case .codex, .claude, .glm, .antigravity: return rawValue
        case .usage, .settings: return nil
        }
    }

    /// Fallback glyph for sections without a bundled app icon.
    var systemImage: String {
        switch self {
        case .codex:       return "chevron.left.forwardslash.chevron.right"
        case .claude:      return "sparkles"
        case .glm:         return "cube"
        case .antigravity: return "bolt.fill"
        case .usage:       return "chart.bar.xaxis"
        case .settings:    return "gearshape"
        }
    }

    var accent: Color {
        switch self {
        case .codex:       return .teal
        case .claude:      return .orange
        case .glm:         return .blue
        case .antigravity: return .purple
        case .usage:       return .green
        case .settings:    return .gray
        }
    }
}
