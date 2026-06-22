import SwiftUI

// MARK: - 额度分级配色

/// 按剩余百分比把额度窗口分成四档，决定卡片里大号数字与进度条的颜色。
enum QuotaTone {
    case healthy   // 充足
    case low       // 偏低
    case critical  // 紧张
    case unknown   // 无数据

    static func from(remainingPercent: Int?) -> QuotaTone {
        guard let percent = remainingPercent else { return .unknown }
        if percent >= 50 { return .healthy }
        if percent >= 20 { return .low }
        return .critical
    }

    var color: Color {
        switch self {
        case .healthy:  return .green
        case .low:      return .orange
        case .critical: return .red
        case .unknown:  return .secondary
        }
    }
}

// MARK: - 设计 token

enum Theme {
    static let cornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
    static let spacing: CGFloat = 18
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let contentPadding: CGFloat = 24

    /// 卡片表面材质，浅/深色模式自动适配。
    static let cardBackground: Material = .regularMaterial
    /// 整窗背景材质。
    static let panelBackground: Material = .thinMaterial
}

// MARK: - 统一卡片表面

/// 全 app 统一的卡片底：材质 + 细描边 + 连续圆角。用 `.cardSurface()` 套在任意内容上。
struct CardSurface: ViewModifier {
    var padded = true

    func body(content: Content) -> some View {
        content
            .padding(padded ? Theme.cardPadding : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(padded: Bool = true) -> some View {
        modifier(CardSurface(padded: padded))
    }
}

// MARK: - 通用小组件

/// 标题旁的胶囊徽标（套餐 / 等级等）。
struct TagBadge: View {
    let text: String
    var tint: Color = .blue
    var muted: Bool = false

    var body: some View {
        let color = muted ? Color.secondary : tint
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// 工具栏里的刷新按钮（带进行中态）。
struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .disabled(isRefreshing)
        .help("立即刷新")
    }
}

/// 内联提示横幅（错误 / 警告）。
struct InlineBanner: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }
}

/// 面板底部的灰色说明脚注（带图标）。
struct FootnoteRow: View {
    let text: String
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - 进度条

struct ProgressBar: View {
    let remainingPercent: Int?
    let tone: QuotaTone

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tone.color, tone.color.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    private var fraction: Double {
        guard let percent = remainingPercent else { return 0 }
        return max(0, min(1, Double(percent) / 100))
    }
}

// MARK: - 卡片数据模型

/// 统一 Codex / GLM 两种窗口类型的展示数据，避免卡片组件依赖具体模型。
struct QuotaStatModel {
    var remainingPercent: Int?
    var usedPercent: Int?
    var absoluteText: String?   // 例如 GLM 的 "remaining/total"
    var resetsAt: Date?
}

// MARK: - 额度卡片

struct QuotaStatCard: View {
    let title: String
    let model: QuotaStatModel?

    private var tone: QuotaTone { QuotaTone.from(remainingPercent: model?.remainingPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model?.remainingPercent.map { "\($0)%" } ?? "--")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(tone.color)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let used = model?.usedPercent {
                    Text("已用 \(used)%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ProgressBar(remainingPercent: model?.remainingPercent, tone: tone)

            if let absolute = model?.absoluteText {
                Text(absolute)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("重置", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model?.resetsAt.map { Self.resetFormatter.string(from: $0) } ?? "--")
                    .foregroundStyle(.primary)
            }
            .font(.caption)
        }
        .cardSurface()
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - 后台运行状态

enum AgentStatus: Sendable {
    case running
    case stopped
    case notInstalled
    case checking

    var dotColor: Color {
        switch self {
        case .running:      return .green
        case .stopped:      return .secondary
        case .notInstalled: return .orange
        case .checking:     return .secondary
        }
    }

    var label: String {
        switch self {
        case .running:      return "运行中"
        case .stopped:      return "已停止"
        case .notInstalled: return "未安装"
        case .checking:     return "检查中"
        }
    }

    var isPulsing: Bool { self == .running }
}

struct StatusDot: View {
    let status: AgentStatus
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.dotColor)
                .frame(width: 8, height: 8)
                .scaleEffect(status.isPulsing && pulsing ? 1.3 : 1.0)
                .opacity(status.isPulsing ? (pulsing ? 0.55 : 1.0) : 1.0)
                .animation(
                    status.isPulsing
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { pulsing = status.isPulsing }
        .onChange(of: status) { _, newValue in pulsing = newValue.isPulsing }
    }
}

// MARK: - 后台开关行

struct LaunchAgentToggleRow: View {
    @ObservedObject var controller: LaunchAgentController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.2.circlepath")
                .foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { controller.isRunning },
                set: { controller.setRunning($0) }
            )) {
                Text("后台自动刷新")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(
                controller.status == .notInstalled
                    || controller.status == .checking
                    || controller.isToggling
            )

            Spacer(minLength: 0)

            StatusDot(status: controller.status)
        }
        .cardSurface()
        .help(controller.status == .notInstalled
              ? "未安装后台刷新，请在仓库内运行 script/install.command"
              : "")
    }
}
