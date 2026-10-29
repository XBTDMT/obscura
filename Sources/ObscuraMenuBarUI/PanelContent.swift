// The panel drawn from one PanelSnapshot (design/mockups/unified/menubar.html, "The open panel, in every state").
// Order: banners, the state line, paused / checking / last catch, Recent, the week, a hairline, the menu, the footer.
import SwiftUI
import AppKit
import ObscuraUIKit
import ObscuraJournal
import ObscuraPrefs

struct PanelContent: View {
    var snapshot: PanelSnapshot
    var perform: @MainActor (PanelAction) -> Void
    var loadThumbnail: @MainActor (Entry) async -> NSImage?
    /// Thumbnails already in hand (renders and previews, where `.task` never runs).
    var preloaded: [UUID: NSImage] = [:]
    /// Whether the pause choices are open (`PanelMemory.pauseChoices`); a constant in renders.
    var pauseChoices: Binding<PauseChoicesPresentation> = .constant(PauseChoicesPresentation(trigger: .hover))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.banners) { banner in
                BannerView(banner: banner, perform: perform).padding(.bottom, 8)
            }
            HeaderView(header: snapshot.header)
            VStack(spacing: 8) {
                if let paused = snapshot.paused { PausedCard(paused: paused, perform: perform) }
                if let setup = snapshot.setup { SetupCardView(card: setup, perform: perform) }
                if let checking = snapshot.checking { CheckingCard(checking: checking) }
                if let lastCatch = snapshot.lastCatch {
                    CatchCard(item: lastCatch, perform: perform, loadThumbnail: loadThumbnail,
                              preloaded: preloaded[lastCatch.entryID])
                }
                if let recent = snapshot.recent { RecentCard(recent: recent, perform: perform) }
                WeekCard(week: snapshot.week)
            }
            Rectangle().fill(OColor.separator).frame(height: 1).padding(.vertical, 8).padding(.horizontal, 2)
            MenuRows(items: snapshot.menu, perform: perform, pauseChoices: pauseChoices)
            FooterView(text: snapshot.footer)
        }
        .padding(10)
        .frame(width: OMetric.menuBarPanelWidth, alignment: .topLeading)
    }
}

// MARK: - Banner

struct BannerView: View {
    var banner: PanelSnapshot.Banner
    var perform: @MainActor (PanelAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: banner.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(banner.tone.color)
                .frame(width: 15, height: 15)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(PanelFont.bannerTitle).foregroundStyle(OColor.text1)
                bodyText.font(PanelFont.bannerBody).foregroundStyle(OColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if !banner.buttons.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(banner.buttons) { b in
                            Button(b.title) { perform(b.action) }.buttonStyle(OButtonStyle(b.role.kitRole, size: .small))
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMetric.Radius.l, style: .continuous).fill(banner.tone.soft))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(banner.title))
    }

    /// The body, with its emphasis (a file name) in bold where it occurs.
    private var bodyText: Text {
        guard let emphasis = banner.emphasis, !emphasis.isEmpty, let range = banner.body.range(of: emphasis) else {
            return Text(banner.body)
        }
        return Text(banner.body[..<range.lowerBound]) + Text(emphasis).bold() + Text(banner.body[range.upperBound...])
    }
}

// MARK: - Header

struct HeaderView: View {
    var header: PanelSnapshot.Header

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            HaloDot(tone: header.tone, halo: header.halo).padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(header.title).font(PanelFont.headerTitle).foregroundStyle(OColor.text1)
                Text(header.sentence).font(PanelFont.headerSentence).foregroundStyle(OColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 6, trailing: 4))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Cards

/// A regular (.btn) action button: optional icon, title, optional key hint at 60 %.
struct ActionButtonView: View {
    var button: PanelSnapshot.ActionButton
    var perform: @MainActor (PanelAction) -> Void

    var body: some View {
        Button { perform(button.action) } label: {
            HStack(spacing: 5) {
                if let symbol = button.symbol {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).accessibilityHidden(true)
                }
                Text(button.title)
                if let shortcut = button.shortcut {
                    Text(shortcut.display).fontWeight(.regular).opacity(0.6).accessibilityHidden(true)
                }
            }
            .lineLimit(1)
        }
        .buttonStyle(OButtonStyle(button.role.kitRole))
        .shortcut(button.shortcut)
        .accessibilityLabel(Text(button.title))
    }
}

struct PausedCard: View {
    var paused: PanelSnapshot.Paused
    var perform: @MainActor (PanelAction) -> Void

    var body: some View {
        PanelCard {
            HStack(alignment: .center, spacing: 10) {
                StatusDot(paused.tone)
                VStack(alignment: .leading, spacing: 0) {
                    // Grey keeps the ordinary title; a colour choice draws the word in it (open-calls.html #17, "Red").
                    Text(paused.title).font(PanelFont.itemTitle)
                        .foregroundStyle(paused.tone == .quiet ? OColor.text1 : paused.tone.text)
                    Text(paused.detail).font(PanelFont.itemDetail).foregroundStyle(OColor.text2).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 6)
                Button(paused.resume.title) { perform(paused.resume.action) }
                    .buttonStyle(OButtonStyle(paused.resume.role.kitRole, size: .small))
            }
        }
    }
}

/// The setup card (onboarding.html screen 11): "Setup · 4 of 8 done" with "4 left", the bar, the next step and the one
/// accent button.
struct SetupCardView: View {
    var card: PanelSnapshot.SetupCard
    var perform: @MainActor (PanelAction) -> Void

    var body: some View {
        PanelCard {
            CardTitle(title: card.title) {
                if let remaining = card.remaining { Badge(remaining, tone: .needs) }
            }
            if let progress = card.progress { ProgressTrack(value: progress) }
            HStack(alignment: .center, spacing: 8) {
                if let next = card.next {
                    Text(next).font(PanelFont.itemDetail).foregroundStyle(OColor.text2).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Button(card.button.title) { perform(card.button.action) }
                    .buttonStyle(OButtonStyle(card.button.role.kitRole, size: .small))
            }
            .padding(.top, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text([card.title, card.next].compactMap { $0 }.joined(separator: ", ")))
    }
}

struct CheckingCard: View {
    var checking: PanelSnapshot.Checking

    var body: some View {
        PanelCard {
            CardTitle(title: checking.title) {
                if let position = checking.position { Text(position).monospacedDigit() }
            }
            Text(checking.detail).font(PanelFont.headerSentence).foregroundStyle(OColor.text2)
                .fixedSize(horizontal: false, vertical: true)
            IndeterminateBar().padding(.top, 7)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CatchCard: View {
    var item: PanelSnapshot.Catch
    var perform: @MainActor (PanelAction) -> Void
    var loadThumbnail: @MainActor (Entry) async -> NSImage?
    var preloaded: NSImage?
    @State private var loaded: NSImage?

    private struct ThumbID: Hashable { let id: UUID; let revision: Int }

    var body: some View {
        PanelCard {
            CardTitle(title: String(localized: "Last catch")) { Text(item.timeLabel) }
            HStack(alignment: .top, spacing: 10) {
                Thumbnail(loaded ?? preloaded)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(PanelFont.itemTitle)
                        .foregroundStyle(item.titleTone?.text ?? OColor.text1)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(PanelFont.itemDetail).foregroundStyle(OColor.text2)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: 6) {
                ForEach(item.buttons) { ActionButtonView(button: $0, perform: perform) }
            }
            .padding(.top, 8)
        }
        .task(id: item.entry.map { ThumbID(id: $0.id, revision: $0.revision) }) {
            guard let entry = item.entry else { loaded = nil; return }
            loaded = await loadThumbnail(entry)
        }
    }
}

struct RecentCard: View {
    var recent: PanelSnapshot.Recent
    var perform: @MainActor (PanelAction) -> Void

    var body: some View {
        PanelCard {
            CardTitle(title: String(localized: "Recent")) { Badge(recent.badge) }
            ForEach(Array(recent.rows.enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 0) {
                    if index > 0 { Rectangle().fill(OColor.separator).frame(height: OMetric.hairline) }
                    HStack(alignment: .center, spacing: 10) {
                        StatusDot(row.tone).padding(.horizontal, 4)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title).font(PanelFont.itemTitle)
                                .foregroundStyle(row.titleTone?.text ?? OColor.text1)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.subtitle).font(PanelFont.itemDetail).foregroundStyle(OColor.text2)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            ForEach(row.buttons) { b in
                                Button(b.title) { perform(b.action) }.buttonStyle(OButtonStyle(b.role.kitRole, size: .small))
                            }
                        }
                        .fixedSize()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

struct WeekCard: View {
    var week: PanelSnapshot.Week
    static let statWidth: CGFloat = 72

    var body: some View {
        PanelCard {
            HStack(alignment: .bottom, spacing: 12) {
                stat(week.secrets, week.secretsLabel)
                stat(week.checked, week.checkedLabel)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(week.bars) { bar in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(bar.isZero ? OColor.text3 : OColor.accent.opacity(bar.isToday ? 1 : 0.75))
                                .frame(width: 6, height: bar.height)
                        }
                    }
                    .frame(height: 22, alignment: .bottom)
                    HStack(spacing: 3) {
                        ForEach(week.bars) { bar in
                            Text(bar.initial).font(PanelFont.dayInitial).foregroundStyle(OColor.text3)
                                .fixedSize().frame(width: 6)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(week.accessibilitySummary))
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(n, format: .number).font(OFont.number).foregroundStyle(OColor.text1).lineLimit(1)
            Text(label).font(PanelFont.statLabel).foregroundStyle(OColor.text2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        // Both stats take the mockup's column width, so their labels wrap alike and the numbers line up.
        .frame(width: Self.statWidth, alignment: .leading)
    }
}

// MARK: - Menu

struct MenuRows: View {
    var items: [PanelSnapshot.MenuItem]
    var perform: @MainActor (PanelAction) -> Void
    var pauseChoices: Binding<PauseChoicesPresentation> = .constant(PauseChoicesPresentation(trigger: .hover))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .separator:
                    Rectangle().fill(OColor.separator).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 9)
                case .row(let row):
                    switch row.kind {
                    case .action(let action):
                        Button { perform(action) } label: { MenuRowLabel(row: row) }
                            .buttonStyle(MenuRowButtonStyle())
                            .shortcut(row.shortcut)
                            .accessibilityLabel(Text(row.title))
                    case .pauseMenu(let current):
                        // Above the rows after it, so its pop draws over them.
                        PauseRow(row: row, current: current, perform: perform, choices: pauseChoices).zIndex(1)
                    }
                }
            }
        }
    }
}

/// Pause Protection and its duration pop: For 15 Minutes · For 1 Hour · Until Tomorrow · Until I Resume. The pop is
/// drawn in the panel under the row's right side (menubar.html `.submenu`) and opens on hover or on click as
/// `Settings.pauseChoicesOpen` says (`PauseChoicesPresentation`); picking a time always takes a click.
struct PauseRow: View {
    var row: PanelSnapshot.MenuRow
    var current: PauseChoice
    var perform: @MainActor (PanelAction) -> Void
    @Binding var choices: PauseChoicesPresentation
    @State private var grace: Task<Void, Never>?

    /// The pop's top sits this far below the row's top (menubar.html `.submenu{top:26px}`).
    static let popOffset: CGFloat = 26
    static let popWidth: CGFloat = 160

    var body: some View {
        Button { choices.rowClicked() } label: { MenuRowLabel(row: row) }
            .buttonStyle(MenuRowButtonStyle(lit: choices.isOpen))
            .onHover { inside in waitIfNeeded(choices.rowHover(inside)) }
            .overlay(alignment: .topTrailing) {
                if choices.isOpen {
                    PauseChoicesPop(current: current) { choice in
                        choices.chose()
                        perform(.pause(choice))
                    }
                    .frame(width: Self.popWidth)
                    .onHover { inside in waitIfNeeded(choices.popHover(inside)) }
                    .offset(x: -4, y: Self.popOffset)
                }
            }
            .accessibilityLabel(Text(row.title))
            .accessibilityValue(Text(current.shortTitle))
            .accessibilityHint(Text("Shows how long to pause"))
            .onDisappear { grace?.cancel() }
    }

    /// The pointer left both the row and the pop of a hover-opened pop: close it unless it comes back in time.
    private func waitIfNeeded(_ wait: Bool) {
        grace?.cancel()
        grace = nil
        guard wait else { return }
        grace = Task { @MainActor in
            try? await Task.sleep(for: PauseChoicesPresentation.leaveGrace)
            guard !Task.isCancelled else { return }
            choices.graceEnded()
        }
    }
}

/// The duration pop itself (`.menu.submenu`): the choices with a check on the current one, lit under the pointer.
struct PauseChoicesPop: View {
    var current: PauseChoice
    var choose: @MainActor (PauseChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PauseChoice.allCases) { choice in
                Button { choose(choice) } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 15, alignment: .leading)
                            .opacity(choice == current ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(choice.menuTitle).font(PanelFont.menu).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowButtonStyle())
                .accessibilityLabel(Text(choice.menuTitle))
                .accessibilityAddTraits(choice == current ? .isSelected : [])
            }
        }
        .padding(5)
        // The pop tint on the window colour: drawn inside the panel, it has no blur of its own (menubar.html blurs the
        // rows under it), so an opaque base keeps them from reading through.
        .background {
            let shape = RoundedRectangle(cornerRadius: PanelPresentation.cornerRadius, style: .continuous)
            ZStack { shape.fill(OColor.window); shape.fill(OColor.popover) }
        }
        .overlay(RoundedRectangle(cornerRadius: PanelPresentation.cornerRadius, style: .continuous)
            .strokeBorder(OColor.hairline, lineWidth: OMetric.hairline))
        .shadow(.pop)
        .accessibilityElement(children: .contain)
    }
}

/// `.prog.det`: the 4 pt track with an accent bar at `value` (0…1), for a count that is known.
struct ProgressTrack: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(OColor.fill2)
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(OColor.accent)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .frame(height: 4)
        .padding(.top, 2)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

struct MenuRowLabel: View {
    var row: PanelSnapshot.MenuRow
    @Environment(\.menuRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 12.5))
                .frame(width: 16)
                .opacity(highlighted ? 1 : 0.78)
                .accessibilityHidden(true)
            Text(row.title).font(PanelFont.menu).lineLimit(1)
            Spacer(minLength: 8)
            if let accessory = row.accessory {
                HStack(spacing: 3) {
                    Text(accessory).font(PanelFont.menuAccessory)
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).accessibilityHidden(true)
                }
                .foregroundStyle(highlighted ? Color.white.opacity(0.82) : OColor.text2)
            }
            if let shortcut = row.shortcut {
                Text(shortcut.display).font(PanelFont.menuKey).tracking(0.6)
                    .foregroundStyle(highlighted ? Color.white.opacity(0.82) : OColor.text2)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Footer

struct FooterView: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(OColor.text3).frame(width: 13).padding(.top, 1)
                .accessibilityHidden(true)
            Text(text).font(PanelFont.footer).foregroundStyle(OColor.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 8, leading: 4, bottom: 2, trailing: 4))
    }
}
