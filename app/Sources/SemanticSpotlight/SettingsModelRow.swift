import SwiftUI

/// Settings' language-model row, first in the General group: the label on the left and the state on the right, the same
/// 44 pt row as the others. The download's caption, the progress bar and a failure's message show under it only when needed.
/// A failure's technical details open in a popover, so the failed state needs no more height than the others.
struct LanguageModelRow: View {
    @ObservedObject var model: OnboardingModel
    @State private var showDetails = false

    private var ready: Bool { model.modelReady || model.download == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Language model").font(.system(size: 13)).foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                control
            }
            note
        }
        .padding(.horizontal, 16)
        .padding(.vertical, SettingsRowMetrics.vertical)
        .frame(minHeight: SettingsRowMetrics.height, alignment: .top)
        .layoutProbe("general.model")
    }

    @ViewBuilder private var control: some View {
        if ready {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.success)
        } else if model.verifying && model.download == .idle {
            // An installed model is being checked: neutral, no Download button.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking language model…").font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize()
            }
            .layoutProbe("model.checking")
        } else {
            switch model.download {
            case .idle:
                ThemeButton("Download model", systemImage: "arrow.down.circle", role: .primary, size: .compact) { model.fetchModel() }
                    .layoutProbe("model.primary")
            case .cancelled:
                ThemeButton("Resume download", systemImage: "arrow.down.circle", role: .primary, size: .compact) { model.fetchModel() }
            case .running, .retrying:
                // The numbers in a fixed mono slot, and Cancel beside them.
                HStack(spacing: 10) {
                    let (done, total) = model.downloadedBytes
                    Text(model.download == .running
                         ? (total > 0 ? "\(done / 1_000_000) of \(total / 1_000_000) MB" : "Downloading…")
                         : "Retrying (\(retryAttempt) of \(retryMax))…")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                        .lineLimit(1).fixedSize()
                    DownloadCancelButton(model: model)
                }
            case .failed:
                ThemeButton("Try again", role: .secondary, size: .compact) { model.fetchModel() }
            case .done:
                EmptyView()
            }
        }
    }

    private var retryAttempt: Int {
        if case .retrying(let attempt, _) = model.download { return attempt }
        return 0
    }

    private var retryMax: Int {
        if case .retrying(_, let max) = model.download { return max }
        return 0
    }

    @ViewBuilder private var note: some View {
        if !ready {
            switch model.download {
            case .idle:
                if !model.verifying {   // while an installed model is checked there is nothing to download, so no caption
                    Text("470 MB, once. It is the only thing the app downloads.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .running, .retrying:
                DownloadProgressBar(ease: model.ease, height: 6)
            case .cancelled(let done, let total):
                Text(pausedCaption(done: done, total: total))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message, let detail):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 12)).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    ThemeButton(showDetails ? "Hide details" : "Show details", role: .tertiary, size: .compact) {
                        showDetails.toggle()
                    }
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(width: 360, alignment: .leading)
                    }
                }
            case .done:
                EmptyView()
            }
        }
    }
}
