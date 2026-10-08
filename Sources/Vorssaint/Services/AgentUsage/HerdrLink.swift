// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin
import Foundation

/// One coding-agent tab in herdr, the terminal multiplexer for agents.
struct HerdrAgentTab: Identifiable, Equatable {
    enum Status: String {
        case blocked, working, done, idle, unknown

        /// Waiting on the person first, then work in progress, then the rest.
        var rank: Int {
            switch self {
            case .blocked: return 0
            case .working: return 1
            case .done: return 2
            case .idle: return 3
            case .unknown: return 4
            }
        }
    }

    /// herdr's pane id.
    let id: String
    /// The agent's own session id, as herdr's integration reports it.
    let session: String
    let agent: String
    let status: Status
    let tab: String
    let workspace: String
}

/// Reads herdr's local socket so the island can show agent sessions by the
/// tab they run in, with herdr's own working / needs-you / done state, and
/// jump to one. Nothing is read from the agents' logs here: names come from
/// herdr, which the person runs and labels. Polls only while a card that
/// shows it is on screen, and does nothing when herdr isn't installed.
final class HerdrLink: ObservableObject {
    static let shared = HerdrLink()

    @Published private(set) var tabs: [HerdrAgentTab] = []
    @Published private(set) var reachable = false

    private var timer: Timer?
    private var watchers = 0
    private let queue = DispatchQueue(label: "com.vorssaint.herdr", qos: .utility)

    static var socketPath: String {
        ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? NSHomeDirectory() + "/.config/herdr/herdr.sock"
    }

    /// herdr has run on this Mac; the Tabs card is offered only then.
    static var installed: Bool { FileManager.default.fileExists(atPath: socketPath) }

    func watch() {
        watchers += 1
        guard watchers == 1 else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func tab(forSession session: String) -> HerdrAgentTab? {
        session.isEmpty ? nil : tabs.first { $0.session == session }
    }

    private static var localLogs = Set<String>()
    private static let localLogsLock = NSLock()

    /// Whether this Mac holds the log of a Claude Code session, as a session
    /// running here does; one found stays found.
    static func hasLocalClaudeLog(session: String, home: String = NSHomeDirectory()) -> Bool {
        guard !session.isEmpty, !session.contains("/") else { return false }
        localLogsLock.lock()
        defer { localLogsLock.unlock() }
        if localLogs.contains(session) { return true }
        let projects = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude") + "/projects"
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        guard folders.contains(where: {
            FileManager.default.fileExists(atPath: projects + "/" + $0 + "/" + session + ".jsonl")
        }) else { return false }
        localLogs.insert(session)
        return true
    }

    /// The session id behind a live transcript: Claude Code names each log
    /// after its session.
    static func session(ofLog path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    func refresh() {
        queue.async { [weak self] in
            let fetched = Self.fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.reachable != (fetched != nil) { self.reachable = fetched != nil }
                let next = fetched ?? []
                if next != self.tabs { self.tabs = next }
            }
        }
    }

    /// Brings the pane forward in herdr, then the terminal herdr runs in.
    func focus(_ tab: HerdrAgentTab) {
        queue.async {
            _ = Self.call("pane.focus", ["pane_id": tab.id])
            DispatchQueue.main.async { Self.activateTerminal() }
        }
    }

    // MARK: Socket

    private static func fetch() -> [HerdrAgentTab]? {
        guard installed,
              let panes = call("pane.list")?["panes"] as? [[String: Any]],
              let spaces = call("workspace.list")?["workspaces"] as? [[String: Any]]
        else { return nil }
        // Tab labels are listed per workspace; ask only where an agent runs.
        let busy = Set(panes.filter(isAgent).compactMap { $0["workspace_id"] as? String })
        let tabs = spaces.compactMap { $0["workspace_id"] as? String }.filter(busy.contains).flatMap {
            call("tab.list", ["workspace_id": $0])?["tabs"] as? [[String: Any]] ?? []
        }
        return agentTabs(panes: panes, workspaces: spaces, tabs: tabs)
    }

    private static func isAgent(_ pane: [String: Any]) -> Bool {
        !(pane["agent"] as? String ?? "").isEmpty
    }

    /// herdr's pane, workspace and tab listings, reduced to the agent tabs the
    /// island shows: needing the person first, then working, then the rest,
    /// each group in herdr's own order.
    static func agentTabs(panes: [[String: Any]], workspaces: [[String: Any]],
                          tabs: [[String: Any]]) -> [HerdrAgentTab] {
        var workspaceLabels: [String: String] = [:]
        for space in workspaces {
            if let id = space["workspace_id"] as? String { workspaceLabels[id] = space["label"] as? String ?? "" }
        }
        var tabLabels: [String: String] = [:]
        for tab in tabs {
            if let id = tab["tab_id"] as? String { tabLabels[id] = tab["label"] as? String ?? "" }
        }
        let found = panes.enumerated().compactMap { index, pane -> (Int, HerdrAgentTab)? in
            guard isAgent(pane), let id = pane["pane_id"] as? String else { return nil }
            let title = (pane["terminal_title_stripped"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let label = tabLabels[pane["tab_id"] as? String ?? ""] ?? ""
            return (index, HerdrAgentTab(
                id: id,
                session: (pane["agent_session"] as? [String: Any])?["value"] as? String ?? "",
                agent: pane["agent"] as? String ?? "",
                status: HerdrAgentTab.Status(rawValue: pane["agent_status"] as? String ?? "") ?? .unknown,
                // A numbered tab says nothing; the agent's own title says more.
                tab: label.allSatisfy(\.isNumber) && !title.isEmpty ? title : label,
                workspace: workspaceLabels[pane["workspace_id"] as? String ?? ""] ?? ""))
        }
        return found.sorted { ($0.1.status.rank, $0.0) < ($1.1.status.rank, $1.0) }.map(\.1)
    }

    /// One request and its reply, each a line of JSON, over the Unix socket.
    private static func call(_ method: String, _ params: [String: Any] = [:]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let request: [String: Any] = ["id": "vorssaint:\(method)", "method": method, "params": params]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == payload.count else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while reply.last != 0x0A {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            reply.append(chunk, count: count)
            if reply.count > 8 << 20 { return nil }
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
        return object["result"] as? [String: Any]
    }

    // MARK: Terminal

    /// Terminals herdr is commonly run in, most specific first.
    private static let terminals = [
        "com.github.wez.wezterm", "com.mitchellh.ghostty", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "org.alacritty", "dev.warp.Warp-Stable", "com.apple.Terminal",
    ]

    private static func activateTerminal() {
        let running = NSWorkspace.shared.runningApplications
        for id in terminals {
            if let app = running.first(where: { $0.bundleIdentifier == id }) {
                app.activate()
                return
            }
        }
    }
}
