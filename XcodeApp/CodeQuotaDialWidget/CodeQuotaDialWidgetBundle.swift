import CodexQuotaDialWidget
import AntigravityQuotaDialWidget
import ClaudeQuotaDialWidget
import GLMQuotaDialWidget
import SwiftUI
import WidgetKit

@main
struct CodeQuotaDialWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexQuotaDialWidget()
        ClaudeQuotaDialWidget()
        GLMQuotaDialWidget()
        AntigravityQuotaDialWidget()
    }
}
