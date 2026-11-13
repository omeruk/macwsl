import SwiftUI

/// The distributions screen (⌘⇧L), a tab of its own, as in `Distributions.dc.html`.
///
/// It shows what the daemon reported: while the screen is visible, the provider follows the
/// daemon's snapshots, never a timer of its own. The actions on the selected distribution are
/// commands of the registry, whose keys the hint bar shows: the screen looks each typed key up
/// there. The details box and the memory chart appear independently, each once the selected
/// distribution has data for it.
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
                !selected.details.isEmpty || MemoryChartBox.hasData(selected)
            {
                // Each half keeps its place, so that a box that appears moves nothing.
                HStack(spacing: 10) {
                    if selected.details.isEmpty {
                        Color.clear.frame(height: 0)
                    } else {
                        DistributionDetailsBox(distribution: selected)
                    }
                    if MemoryChartBox.hasData(selected) {
                        MemoryChartBox(distribution: selected)
                    } else {
                        Color.clear.frame(height: 0)
                    }
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

/// A bar chart of memory use over the last 60 seconds, in the theme's blue slot: one slot per
/// sample, the newest on the right, scaled to the machine's memory size. A sample whose memory
/// is not known, and a slot before the first sample, draw no bar.
struct MemoryChartBox: View {
    let distribution: DistributionInfo
    @Environment(\.chrome) private var chrome
    @Environment(\.ansi) private var ansi

    /// Whether the distribution has a sample to draw.
    static func hasData(_ distribution: DistributionInfo) -> Bool {
        distribution.memoryHistory.contains { $0 != nil }
    }

    /// The bars' values, `historyLength` slots, oldest first.
    static func slots(_ history: [UInt64?]) -> [UInt64?] {
        let count = DaemonDistributions.historyLength
        let recent = history.suffix(count)
        return Array(repeating: nil, count: count - recent.count) + recent
    }

    var body: some View {
        let slots = Self.slots(distribution.memoryHistory)
        let peak = max(
            distribution.memoryLimit ?? slots.compactMap { $0 }.max() ?? 1, 1)
        Box(
            title: "memory", trailingTitle: "last 60 s", titleColor: chrome.text,
            trailingTitleColor: chrome.textSecondary, borderColor: chrome.line
        ) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { _, value in
                            let share = CGFloat(min(value ?? 0, peak)) / CGFloat(peak)
                            Rectangle()
                                .fill(value == nil ? Color.clear : ansi.blue.color)
                                .frame(
                                    height: value == nil ? 0 : max(2, geometry.size.height * share))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                HStack {
                    Text("60s").chromeStyle(chrome.textMuted)
                    Spacer()
                    caption
                    Spacer()
                    Text("0s").chromeStyle(chrome.textMuted)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory over the last 60 seconds: \(Self.caption(distribution))")
    }

    /// The caption's parts, `412M` `now · 8.0G limit`, with only the figures that are known.
    /// The first part is the memory in use, drawn in the numbers' color as in the board.
    static func captionParts(_ distribution: DistributionInfo) -> (memory: String?, rest: String) {
        let limit = distribution.memoryLimit.map { "\(FigureFormat.bytes($0)) limit" }
        guard let memory = distribution.memory else { return (nil, limit ?? "") }
        return (memory, [" now", limit].compactMap { $0 }.joined(separator: " · "))
    }

    static func caption(_ distribution: DistributionInfo) -> String {
        let parts = captionParts(distribution)
        return (parts.memory ?? "") + parts.rest
    }

    private var caption: Text {
        let parts = Self.captionParts(distribution)
        let memory = Text(parts.memory ?? "").foregroundStyle(ansi.magenta.color)
        return (memory + Text(parts.rest).foregroundStyle(chrome.textSecondary.color))
            .font(MawFonts.chromeFont())
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
                .init(
                    "disk image", "~/Library/Application Support/maw/distros/ubuntu-24.04/disk.img"),
                .init("boot", "271 ms to agent", role: .timing),
                .init("host memory", "710M", role: .number),
            ],
            memoryHistory: [4, 5, 5, 6, 7, 7, 8, 8, 9, 12, 18, 22, 21, 19, 16, 14, 13, 12, 12, 11]
                .map { UInt64($0) << 24 },
            memoryLimit: 8 << 30),
        DistributionInfo(
            name: "debian-13", state: .running, memory: "188M", cpu: "0.0%", disk: "1.4G/64G",
            uptime: "41m", kernel: "6.18.57-maw"),
        DistributionInfo(
            name: "alpine-3.22", state: .stopped, disk: "0.2G/16G", kernel: "6.18.57-maw",
            details: [
                .init("default", "no", role: .muted), .init("user", "root"),
                .init(
                    "disk image", "~/Library/Application Support/maw/distros/alpine-3.22/disk.img"),
            ]),
    ]
}
