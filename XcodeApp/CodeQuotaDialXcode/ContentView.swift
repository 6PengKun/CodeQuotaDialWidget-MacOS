import SwiftUI

struct ContentView: View {
    @State private var selectedDashboard = Dashboard.codex

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Code Quota Dial")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("额度监控")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Picker("", selection: $selectedDashboard) {
                    ForEach(Dashboard.allCases) { dashboard in
                        Text(dashboard.title)
                            .tag(dashboard)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedDashboard {
                case .codex:
                    CodexQuotaPanelView()
                case .claude:
                    ClaudeQuotaPanelView()
                case .glm:
                    GLMQuotaPanelView()
                case .antigravity:
                    AntigravityQuotaPanelView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panelBackground)
    }
}

private enum Dashboard: String, CaseIterable, Identifiable {
    case codex
    case claude
    case glm
    case antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .glm:
            return "GLM"
        case .antigravity:
            return "Antigravity"
        }
    }
}
