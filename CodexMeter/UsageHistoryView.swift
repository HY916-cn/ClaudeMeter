import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageHistoryView: View {
    @ObservedObject var service: CodexUsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: UsageHistoryModel
    @State private var tokenRange: TokenActivityRange = .month
    @State private var showsClearConfirmation = false
    @State private var actionError: String?

    var body: some View {
        ZStack {
            HistoryBackdrop()
            historyContent
        }
        .frame(
            minWidth: 700,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 820,
            maxHeight: .infinity
        )
        .background(HistoryWindowConfigurator(title: L10n.string("history.title")))
        .task(id: loadIdentifier) {
            await history.load()
        }
        .alert(L10n.string("history.clear.title"), isPresented: $showsClearConfirmation) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button(L10n.string("history.clear.confirm"), role: .destructive) {
                Task { await history.clearAll() }
            }
        } message: {
            Text(L10n.string("history.clear.message"))
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if #available(macOS 26.0, *) {
            historyScrollView
                .safeAreaBar(edge: .top, spacing: 0) {
                    header
                }
        } else {
            historyScrollView
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        header
                        Divider().opacity(0.45)
                    }
                    .background(.ultraThinMaterial)
                }
        }
    }

    private var historyScrollView: some View {
        ScrollView {
            cardStack
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 24)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("history.title"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(L10n.string("history.summary.local"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if history.isLoading {
                ProgressView().controlSize(.small)
            }

        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cardStack: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 18) {
                cards
            }
        } else {
            cards
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 18) {
            tokenActivityCard
            storageCard

            if let error = history.errorMessage ?? actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var tokenActivityCard: some View {
        let points = tokenPoints
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("history.tokens.title"))
                        .font(.title3.weight(.bold))
                    Text(L10n.string("history.tokens.local_help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HistoryRangePicker(
                options: TokenActivityRange.allCases,
                selection: $tokenRange,
                title: { $0.localizedName }
            )

            if service.isTokenUsageUnavailable && tokenSnapshot == nil {
                EmptyHistoryView(
                    icon: "chart.bar.fill",
                    title: L10n.string("history.tokens.unavailable"),
                    message: service.tokenUsageErrorMessage
                        ?? L10n.string("history.tokens.unavailable_help")
                )
            } else if points.isEmpty {
                EmptyHistoryView(
                    icon: "chart.bar.fill",
                    title: L10n.string("history.tokens.no_daily"),
                    message: L10n.string("history.tokens.unavailable_help")
                )
            } else {
                HStack(spacing: 28) {
                    MetricHeadline(
                        title: tokenRange.localizedName,
                        value: compactToken(tokenTotal(points)),
                        tint: HistoryPalette.accentBright
                    )
                    MetricHeadline(
                        title: L10n.string("history.tokens.latest"),
                        value: compactToken(points.last?.tokens),
                        tint: .primary
                    )
                    MetricHeadline(
                        title: L10n.string("history.tokens.peak_period"),
                        value: compactToken(points.map(\.tokens).max()),
                        tint: .primary
                    )
                    Spacer()
                }

                CompactTokenActivityChart(
                    points: points,
                    showsAxes: true,
                    granularity: tokenRange.chartGranularity,
                    isInteractive: true,
                    range: tokenRange
                )
                    .frame(height: 220)

                if let summary = tokenSnapshot?.summary {
                    tokenSummary(summary)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .historyGlassCard()
    }

    private func tokenSummary(_ summary: TokenUsageSummary) -> some View {
        HStack(spacing: 10) {
            SummaryPill(
                title: L10n.string("history.tokens.lifetime"),
                value: compactToken(summary.lifetimeTokens)
            )
            SummaryPill(
                title: L10n.string("history.tokens.current_streak"),
                value: formattedDays(summary.currentStreakDays)
            )
            SummaryPill(
                title: L10n.string("history.tokens.longest_streak"),
                value: formattedDays(summary.longestStreakDays)
            )
            SummaryPill(
                title: L10n.string("history.tokens.longest_turn"),
                value: formattedDuration(summary.longestRunningTurnSeconds)
            )
        }
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("history.storage.title"))
                .font(.headline)

            HStack {
                Picker(L10n.string("history.retention"), selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.localizedName).tag(retention)
                    }
                }
                .onChange(of: settings.historyRetention) { retention in
                    Task { await history.applyRetention(retention) }
                }

                Spacer()

                Text(ByteCountFormatter.string(
                    fromByteCount: history.storageSize,
                    countStyle: .file
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(L10n.string("history.export")) { exportHistory() }
                Button(L10n.string("history.clear"), role: .destructive) {
                    showsClearConfirmation = true
                }
                Spacer()
            }

            Text(L10n.string("history.storage.privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .historyGlassCard()
    }

    private var tokenSnapshot: TokenUsageSnapshot? {
        history.tokenUsage ?? service.tokenUsage
    }

    private var tokenPoints: [TokenChartPoint] {
        TokenChartData.displayPoints(
            TokenChartData.points(from: tokenSnapshot),
            range: tokenRange,
            now: Date()
        )
    }

    private func tokenTotal(_ points: [TokenChartPoint]) -> Int64 {
        points.reduce(0) { partial, point in
            let (sum, overflow) = partial.addingReportingOverflow(point.tokens)
            return overflow ? Int64.max : sum
        }
    }

    private var loadIdentifier: String {
        String(history.dataRevision)
    }

    private func compactToken(_ value: Int64?) -> String {
        value.map { CompactTokenFormatter.string($0, locale: L10n.locale) } ?? "—"
    }

    private func formattedDays(_ value: Int64?) -> String {
        value.map { L10n.format("history.days.format", $0) } ?? "—"
    }

    private func formattedDuration(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return L10n.compactDuration(seconds: value)
    }

    private func exportHistory() {
        Task {
            do {
                let data = try await history.exportCSV()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "ClaudeMeter-History.csv"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct MetricHeadline: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct HistoryRangePicker<Option: Identifiable & Equatable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(options) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.caption.weight(selection == option ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if selection == option {
                                Capsule().fill(HistoryPalette.accent.opacity(0.20))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == option ? HistoryPalette.accentBright : .secondary)
            }
        }
        .padding(4)
        .background(.secondary.opacity(0.08), in: Capsule())
    }
}

private struct EmptyHistoryView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(HistoryPalette.accent)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

private struct HistoryBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
            RadialGradient(
                colors: [HistoryPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

/// Configures the history scene as a content-integrated macOS window while
/// keeping the native traffic-light controls and full-screen behavior.
private struct HistoryWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowConfigurationView {
        WindowConfigurationView(title: title)
    }

    func updateNSView(_ nsView: WindowConfigurationView, context: Context) {
        nsView.configure(title: title)
    }

    final class WindowConfigurationView: NSView {
        private var currentTitle: String

        init(title: String) {
            currentTitle = title
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfiguration()
        }

        func configure(title: String) {
            currentTitle = title
            applyConfiguration()
        }

        private func applyConfiguration() {
            guard let window else { return }
            window.title = currentTitle
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert([.fullSizeContentView, .resizable])
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }
}
