import SwiftUI

/// The distributions screen (⌘⇧L), a tab of its own, as in `Distributions.dc.html`.
///
/// It shows what the daemon reported and asks again when it opens and after each action, never
/// on a timer. The actions on the selected distribution are commands of the registry, whose
/// keys the hint bar shows: the screen looks each typed key up there. The details box and the
/// memory chart appear once a distribution has data for them, which phase 11c supplies; until
/// then previews with sample data cover them.
struct DistributionsScreen: View {
    let model: WindowModel
    @FocusState private var focused: Bool

    var body: some View {
        DistributionsContent(
            listing: model.distributionListing, host: .current,
            selection: model.selectedDistribution?.name, select: model.selectDistribution
        )
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 0, trailing: 10))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            model.perform(.back)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveDistributionSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveDistributionSelection(by: 1)
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // A key held down does not repeat an action, and ⌘, ⌃, and ⌥ make another key.
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
                return .ignored
            }
            let key: KeyShortcut.Key =
                press.key == .return ? .return : .character(press.key.character)
            guard let command = model.registry.command(forKey: key, on: .distributions) else {
                return .ignored
            }
            model.perform(command)
            return .handled
        }
    }
}

/// The screen's content, separate from the window model so that previews can supply data.
struct DistributionsContent: View {
    let listing: DistributionListing
    let host: HostSummary
    /// The name of the selected distribution.
    let selection: String?
    let select: (String) -> Void
    @Environment(\.chrome) private var chrome
    @Environment(\.ansi) private var ansi

    /// Column widths from the design README; KERNEL takes the rest.
    static let columns: [CGFloat] = [28, 200, 110, 120, 90, 110, 90]
    static let headers = ["", "NAME", "STATE", "MEMORY", "CPU", "DISK", "UPTIME", "KERNEL"]
    static let rowHeight: CGFloat = 26

    /// The daemon's list, or `nil` while there is none to show.
    private var listed: [DistributionInfo]? {
        guard case .listed(let distributions) = listing else { return nil }
        return distributions
    }

    var body: some View {
        VStack(spacing: 10) {
            // The count is the daemon's: none is shown until it has answered.
            Box(
                title: "distributions", titleDetail: listed.map { "(\($0.count))" },
                trailingTitle: host.description,
                titleColor: chrome.text, trailingTitleColor: chrome.textSecondary,
                borderColor: chrome.lineStrong
            ) {
                VStack(spacing: 0) {
                    row(Self.headers.map { ($0, chrome.textSecondary) }, background: nil)
                        .accessibilityAddTraits(.isHeader)
                    switch listing {
                    case .waiting:
                        EmptyView()
                    case .failed(let text):
                        // maw's message and suggestion, each of which may take several lines.
                        // The limit bounds the height that a narrow window needs, which
                        // would otherwise grow the window.
                        Text(text.trimmingCharacters(in: .newlines))
                            .font(MawFonts.chromeFont())
                            .foregroundStyle(chrome.problem.color)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                    case .listed(let distributions) where distributions.isEmpty:
                        Text("no distributions installed").chromeStyle(chrome.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: Self.rowHeight)
                    case .listed(let distributions):
                        ForEach(distributions) { item in
                            distributionRow(item, selected: item.name == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { select(item.name) }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let selected = listed?.first(where: { $0.name == selection }),
                !selected.details.isEmpty || !selected.memoryHistory.isEmpty
            {
                HStack(spacing: 10) {
                    DistributionDetailsBox(distribution: selected)
                    MemoryChartBox(distribution: selected)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Running is `status.ok` and stopped is `text.muted`, as in the design; a machine on its
    /// way from one to the other takes the theme's yellow slot.
    private func stateColor(_ state: DistributionInfo.State) -> ThemeColor {
        switch state {
        case .running: chrome.statusOK
        case .starting, .stopping: ansi.yellow
        case .stopped: chrome.textMuted
        }
    }

    private func distributionRow(_ item: DistributionInfo, selected: Bool) -> some View {
        let plain = selected ? chrome.textSelected : chrome.text
        let muted = selected ? chrome.textSelectedSecondary : chrome.textMuted
        let number = selected ? chrome.textSelected : ansi.magenta
        let state = selected ? chrome.textSelected : stateColor(item.state)
        // A figure that the daemon has not reported is an empty cell, never a placeholder.
        return row(
            [
                (item.isDefault ? "*" : " ", selected ? chrome.textSelected : chrome.accent),
                (item.name, plain), (item.state.rawValue, state), (item.memory ?? "", number),
                (item.cpu ?? "", number), (item.disk ?? "", number), (item.uptime ?? "", plain),
                (item.kernel ?? "", muted),
            ], background: selected ? chrome.text : nil
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func row(_ cells: [(String, ThemeColor)], background: ThemeColor?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let text = Text(cell.0).chromeStyle(cell.1)
                if index < Self.columns.count {
                    text.frame(width: Self.columns[index], alignment: .leading)
                } else {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: Self.rowHeight)
        .background(background?.color ?? .clear, ignoresSafeAreaEdges: [])
    }
}

/// `key value` rows for the selected distribution.
struct DistributionDetailsBox: View {
    let distribution: DistributionInfo
    @Environment(\.chrome) private var chrome
    @Environment(\.ansi) private var ansi

    var body: some View {
        Box(title: distribution.name, titleColor: chrome.text, borderColor: chrome.line) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(distribution.details, id: \.key) { detail in
                    HStack(spacing: 0) {
                        Text(detail.key).chromeStyle(chrome.textSecondary)
                            .frame(width: MawFonts.chromeCharacterWidth * 12, alignment: .leading)
                        Text(detail.value).chromeStyle(color(detail.role))
                            .truncationMode(.middle)
                    }
                    .frame(height: MawFonts.chromeLineHeight)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func color(_ role: DistributionInfo.Detail.Role) -> ThemeColor {
        let palette = ansi
        return switch role {
        case .plain: chrome.text
        case .muted: chrome.textMuted
        case .positive: chrome.statusOK
        case .number: palette.magenta
        case .link: palette.blue
        case .timing: palette.cyan
        }
    }
}

/// A bar chart of memory use over the last 60 seconds, in the theme's blue slot.
struct MemoryChartBox: View {
    let distribution: DistributionInfo
    @Environment(\.chrome) private var chrome
    @Environment(\.ansi) private var ansi

    var body: some View {
        let history = distribution.memoryHistory
        let peak = max(history.max() ?? 1, distribution.memoryLimit ?? 1, 1)
        Box(
            title: "memory", trailingTitle: "last 60 s", titleColor: chrome.text,
            trailingTitleColor: chrome.textSecondary, borderColor: chrome.line
        ) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, value in
                            Rectangle()
                                .fill(ansi.blue.color)
                                .frame(
                                    height: max(
                                        2, geometry.size.height * CGFloat(value) / CGFloat(peak)))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                HStack {
                    Text("60s").chromeStyle(chrome.textMuted)
                    Spacer()
                    Text(caption).chromeStyle(chrome.textSecondary)
                    Spacer()
                    Text("0s").chromeStyle(chrome.textMuted)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory over the last 60 seconds: \(caption)")
    }

    private var caption: String {
        let now = distribution.memory ?? "—"
        guard let limit = distribution.memoryLimit else { return "\(now) now" }
        return
            "\(now) now · \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .memory)) limit"
    }
}

#Preview("Distributions, sample data") {
    @Previewable @State var selection = DistributionInfo.samples[0].name
    DistributionsContent(
        listing: .listed(DistributionInfo.samples),
        host: HostSummary(physicalMemory: 16 << 30, processorCount: 10, macOSVersion: [27, 0, 0]),
        selection: selection, select: { selection = $0 }
    )
    .padding(10)
    .frame(width: 1280, height: 560)
    .background(Color.black)
}

#Preview("Distributions, empty") {
    DistributionsContent(listing: .listed([]), host: .current, selection: nil, select: { _ in })
        .padding(10)
        .frame(width: 1280, height: 300)
        .background(Color.black)
}

extension DistributionInfo {
    /// Sample data for previews only. The running app never shows it.
    static let samples: [DistributionInfo] = [
        DistributionInfo(
            name: "ubuntu-24.04", state: .running, isDefault: true, memory: "412M", cpu: "0.4%",
            disk: "3.1G/64G", uptime: "2h 14m", kernel: "6.18.57-maw",
            details: [
                .init("default", "yes", role: .positive), .init("user", "omer"),
                .init("ip", "192.168.64.3", role: .number),
                .init("forwarded", "localhost:8000 → 8000", role: .link),
                .init("mounts", "/mnt/mac ← ~", role: .link),
                .init("disk image", "~/Library/…/ubuntu-24.04/disk.img"),
                .init("boot", "271 ms to agent", role: .timing),
            ],
            memoryHistory: [4, 5, 5, 6, 7, 7, 8, 8, 9, 12, 18, 22, 21, 19, 16, 14, 13, 12, 12, 11]
                .map { UInt64($0) << 24 },
            memoryLimit: 2 << 30),
        DistributionInfo(
            name: "debian-13", state: .running, memory: "188M", cpu: "0.0%", disk: "1.4G/64G",
            uptime: "41m", kernel: "6.18.57-maw"),
        DistributionInfo(
            name: "alpine-3.22", state: .stopped, disk: "0.2G/16G", kernel: "6.18.57-maw"),
    ]
}
