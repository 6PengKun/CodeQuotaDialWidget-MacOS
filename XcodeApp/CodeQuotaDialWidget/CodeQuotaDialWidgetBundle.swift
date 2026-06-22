import CodexQuotaDialWidget
import AntigravityQuotaDialWidget
import ClaudeQuotaDialWidget
import GLMQuotaDialWidget
import UsageQuotaDialWidget
import SwiftUI
import WidgetKit

@main
struct CodeQuotaDialWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexQuotaDialWidget()
        ClaudeQuotaDialWidget()
        GLMQuotaDialWidget()
        AntigravityQuotaDialWidget()
        UsageQuotaDialWidget()
    }
}
