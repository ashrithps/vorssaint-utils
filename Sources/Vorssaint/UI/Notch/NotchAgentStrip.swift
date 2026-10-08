// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The closed island while an agent works: its mark on one side of the
/// camera, one reading the person chose on the other. The wings are as wide
/// as the reading, and both sit at the ends, where the island shows.
struct NotchAgentStrip: View {
    @ObservedObject var service: NotchService
    /// Where the island draws it: its own strip as of the last update, or
    /// another display's when the island shows on every display.
    var displayGeometry: NotchGeometry? = nil
    @ObservedObject private var usage = AgentUsageService.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var herdr = HerdrLink.shared
    @AppStorage(DefaultsKey.notchAgentsReadout) private var readout = NotchAgentReadout.elapsed.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitDisplay) private var display = NotchAgentLimitDisplay.remaining.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitFocus) private var focus = NotchAgentLimitFocus.mostUsed.rawValue

    private func working(_ live: [AgentLiveSession]) -> [AgentProvider] {
        AgentProvider.allCases.filter { provider in live.contains { $0.provider == provider } }
    }

    var body: some View {
        // The last agent stopping empties the list before the strip has left.
        NotchStripHold(usage.snapshot.live, shows: !usage.snapshot.live.isEmpty) { strip(live: $0) }
            .onAppear { if HerdrLink.installed { herdr.watch() } }
            .onDisappear { if HerdrLink.installed { herdr.unwatch() } }
    }

    @ViewBuilder private func strip(live: [AgentLiveSession]) -> some View {
        // Resolve layout once per presentation update. The timeline captures
        // these values, so ticking the clock never remeasures the island or
        // walks the preferences for every font, inset and frame.
        let geometry = displayGeometry ?? service.compactActivityGeometry
        let working = working(live)
        let tint = working.first?.tint ?? .white
        let budget = geometry.compactActivityContentHeight - NotchLayout.compactEdgeGap * 2
        let iconSize = min(working.count > 1 ? 11.0 : 14.0, max(8, budget - 4))
        let textSize = NotchAgentSupport.stripTextSize(height: geometry.compactActivityContentHeight)
        let iconInset = !geometry.compactActivityUsesFooter
            ? geometry.compactActivityEdgeInset(boxHeight: iconSize + 4, radius: (iconSize + 4) / 2) : 0
        let named = NotchAgentSupport.stripTab(live: live, tabs: herdr.tabs)
        let nameText = named.map(NotchAgentSupport.stripTabText)
        let showsName = nameText != nil && geometry.compactActivityWingWidth > NotchAgentSupport.stripWingRange.upperBound
        let dots = showsName ? [] : NotchAgentSupport.stripDots(tabs: herdr.tabs)
        let waiting = NotchAgentSupport.stripWaiting(tabs: herdr.tabs)
        let context = readout == NotchAgentReadout.limit.rawValue ? nil : NotchAgentSupport.stripContext(live: live)
        // What changes the wings' width, measured again by the service.
        let layout = "\(nameText ?? "")|\(dots.count)|\(waiting > 0 ? String(waiting) : "")|\(context != nil)"
        let textInset = !geometry.compactActivityUsesFooter
            ? geometry.compactActivityEdgeInset(boxHeight: textSize * 0.72, radius: 0) : 0
        HStack(spacing: 0) {
            Button { service.openActivity(.agents) } label: {
                HStack(spacing: 1) {
                    if geometry.compactActivityWingWidth >= 28 {
                        ForEach(working) { NotchAgentGlyph(provider: $0, size: iconSize) }
                    }
                    if let named, let nameText, showsName {
                        Text(nameText)
                            .font(.system(size: NotchAgentSupport.stripNameSize, weight: .medium))
                            .foregroundStyle(named.tab.status == .blocked ? Color.orange : Color.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 4)
                    } else if !dots.isEmpty {
                        HStack(spacing: 1) {
                            ForEach(Array(dots.enumerated()), id: \.offset) { NotchAgentTabDot(status: $0.element) }
                        }
                        .padding(.leading, 3)
                    }
                }
                // A new name, dot or gauge needs the wings measured again, as a new reading does.
                .onChange(of: layout) { _, _ in DispatchQueue.main.async { service.refreshPresentation() } }
                .padding(.leading, iconInset)
                .frame(width: geometry.compactActivityWingWidth, height: geometry.compactActivityContentHeight,
                       alignment: .leading)
                .contentShape(Rectangle())
            }
            Color.clear.frame(width: geometry.compactActivityCameraGap)
            Button { service.openActivity(.agents) } label: {
                Group {
                    if waiting > 0, geometry.compactActivityWingWidth >= 30 {
                        // A tab waiting on the person outranks every reading.
                        HStack(spacing: 3) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: textSize * 0.8, weight: .semibold))
                            Text(String(waiting))
                                .font(.system(size: textSize, weight: .medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    } else if geometry.compactActivityWingWidth >= 42 {
                        HStack(spacing: 4) {
                            if let context {
                                NotchAgentRing(value: context, tint: NotchAgentTabDot.contextTint(context), lineWidth: 2)
                                    .frame(width: NotchAgentSupport.stripRingSize, height: NotchAgentSupport.stripRingSize)
                            }
                            readingView(live: live, tint: tint, textSize: textSize)
                        }
                    }
                }
                .padding(.trailing, textInset)
                .frame(width: geometry.compactActivityWingWidth, height: geometry.compactActivityContentHeight,
                       alignment: .trailing)
                .contentShape(Rectangle())
            }
        }
        .frame(height: geometry.compactActivityContentHeight)
        .padding(.horizontal, geometry.compactActivityHorizontalPadding)
        .padding(.top, geometry.compactActivityTopPadding)
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([nameText].compactMap { $0 } + working.map(\.displayName)).joined(separator: ", "))
        .accessibilityValue(waiting > 0 ? text.needYou(waiting)
            : ([reading(at: Date(), live: live)] + [context.map { text.contextFull(AgentFormat.percent($0)) }].compactMap { $0 })
                .joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { service.openActivity(.agents) }
        .accessibilityHint(FeatureStrings.notch(l10n.language).open)
    }

    private var text: NotchAgentStrings { FeatureStrings.notchAgents(l10n.language) }

    private func readingView(live: [AgentLiveSession], tint: Color, textSize: CGFloat) -> some View {
        NotchAgentReadoutTimeline(readout: NotchAgentReadout(rawValue: readout) ?? .elapsed) { date in
            let text = reading(at: date, live: live)
            Text(text)
                .font(.system(size: textSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // A reading that gains a digit, like an hour passing, needs
                // wider wings; the service measures the same reading.
                .onChange(of: NotchAgentSupport.readingShape(text)) { _, _ in
                    DispatchQueue.main.async { service.refreshPresentation() }
                }
        }
    }

    private func reading(at now: Date, live: [AgentLiveSession]) -> String {
        var snapshot = usage.snapshot
        snapshot.live = live
        return NotchAgentSupport.stripReading(snapshot, readout: NotchAgentReadout(rawValue: readout) ?? .elapsed,
                                              display: NotchAgentLimitDisplay(rawValue: display) ?? .remaining,
                                              focus: NotchAgentLimitFocus(rawValue: focus) ?? .mostUsed, now: now)
    }
}

/// Keep the original one-second cadence for time-dependent readings, but
/// install no clock at all for values updated by the observed usage snapshot.
struct NotchAgentReadoutTimeline<Content: View>: View {
    let readout: NotchAgentReadout
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if readout.advancesWithClock {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(context.date)
            }
        } else {
            content(.now)
        }
    }
}

/// The resting island's wings: the chosen allowance, by default the one
/// closest to running out, as a ring and a number, or today's API value when
/// no allowance is known.
struct NotchAgentRestingWing: View {
    let leading: Bool
    @ObservedObject private var usage = AgentUsageService.shared
    @AppStorage(DefaultsKey.notchAgentsLimitDisplay) private var display = NotchAgentLimitDisplay.remaining.rawValue
    @AppStorage(DefaultsKey.notchAgentsLimitFocus) private var focus = NotchAgentLimitFocus.mostUsed.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let snapshot = usage.snapshot
        let limit = NotchAgentSupport.restingLimit(snapshot, focus: NotchAgentLimitFocus(rawValue: focus) ?? .mostUsed, now: now)
        let used = display == NotchAgentLimitDisplay.used.rawValue
        if let limit {
            let tint = agentLimitTint(limit.provider, usedFraction: limit.window.usedFraction)
            if leading {
                NotchAgentRing(value: used ? limit.window.usedFraction : limit.window.remainingFraction,
                               tint: tint, lineWidth: 2)
                    .frame(width: 11, height: 11)
            } else {
                Text(AgentFormat.percent(used ? limit.window.usedFraction : limit.window.remainingFraction))
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } else if let provider = AgentProvider.allCases.first(where: snapshot.seen.contains) {
            if leading {
                NotchAgentMark(provider: provider, size: 10)
            } else {
                Text(AgentFormat.cost(snapshot.usage(.today).total.cost))
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// One herdr agent tab beside the mark: pulsing while it works, orange while
/// it waits on the person, green once it's done and not yet looked at.
struct NotchAgentTabDot: View {
    let status: HerdrAgentTab.Status

    static func contextTint(_ fraction: Double) -> Color {
        fraction >= 0.95 ? .red : fraction >= 0.8 ? .orange : .white.opacity(0.85)
    }

    var body: some View {
        Group {
            switch status {
            case .working: NotchAgentPulse(tint: .white, size: 4)
            case .blocked: Circle().fill(Color.orange).frame(width: 5, height: 5)
            default: Circle().fill(Color.green.opacity(0.9)).frame(width: 5, height: 5)
            }
        }
        .frame(width: NotchAgentSupport.stripDotSlot, height: NotchAgentSupport.stripDotSlot)
        .accessibilityHidden(true)
    }
}
