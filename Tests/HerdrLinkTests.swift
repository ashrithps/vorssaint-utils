// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum HerdrLinkTests {
    static func run(_ suite: TestSuite) {
        suite.run("herdr tabs") { tabs(suite) }
        suite.run("herdr sessions") { sessions(suite) }
        suite.run("herdr strip name") { strip(suite) }
    }

    private static func pane(_ id: String, tab: String, workspace: String = "w1", agent: String? = "claude",
                             status: String = "idle", session: String? = nil, title: String = "") -> [String: Any] {
        var pane: [String: Any] = ["pane_id": id, "tab_id": tab, "workspace_id": workspace,
                                   "agent_status": status, "terminal_title_stripped": title]
        if let agent { pane["agent"] = agent }
        if let session { pane["agent_session"] = ["kind": "id", "value": session] }
        return pane
    }

    private static func tabs(_ suite: TestSuite) {
        let workspaces: [[String: Any]] = [["workspace_id": "w1", "label": "vault"],
                                           ["workspace_id": "w2", "label": "budgetarc"]]
        let tabs: [[String: Any]] = [["tab_id": "t1", "label": "charts tables"], ["tab_id": "t2", "label": "3"],
                                     ["tab_id": "t3", "label": "mac"], ["tab_id": "t4", "label": "services"],
                                     ["tab_id": "t5", "label": "2"]]
        let result = HerdrLink.agentTabs(panes: [
            pane("p1", tab: "t1", status: "working", session: "s1"),
            pane("p2", tab: "t2", status: "done", title: "Smooth cold launch"),
            pane("p3", tab: "t3", status: "blocked", title: "Vault Mac app with drag-and-drop"),
            // A dev server beside an agent is not an agent tab.
            pane("p4", tab: "t4", agent: nil, status: "unknown"),
            pane("p5", tab: "t1", workspace: "w2", status: "working"),
            pane("p6", tab: "t5", status: "sleeping"),
        ], workspaces: workspaces, tabs: tabs)

        suite.expect(result.map(\.id) == ["p3", "p1", "p5", "p2", "p6"],
                     "needing the person first, then working, done, idle; herdr's order within each: \(result.map(\.id))")
        suite.expect(!result.contains { $0.id == "p4" }, "panes without an agent are left out")
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        suite.expect(byID["p3"]?.tab == "mac", "a tab the person named keeps its name over the agent's title")
        suite.expect(byID["p2"]?.tab == "Smooth cold launch", "a numbered tab shows the agent's own title")
        suite.expect(byID["p6"]?.tab == "2", "a numbered tab without a title keeps its number")
        suite.expect(byID["p5"]?.workspace == "budgetarc", "each tab carries its workspace's label")
        suite.expect(byID["p6"]?.status == .unknown, "an unrecognised state reads as unknown")
        suite.expect(byID["p1"]?.session == "s1" && byID["p2"]?.session == "", "sessions come from herdr's agent_session")
        suite.expect(HerdrLink.agentTabs(panes: [], workspaces: workspaces, tabs: tabs).isEmpty,
                     "no panes, no tabs")
    }

    private static func sessions(_ suite: TestSuite) {
        let log = "/Users/someone/.claude/projects/-Users-someone-code/00b43888-5286-485c-afed-ffeb3b9f7691.jsonl"
        suite.expect(HerdrLink.session(ofLog: log) == "00b43888-5286-485c-afed-ffeb3b9f7691",
                     "a Claude log is named after its session")
    }

    private static func strip(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func live(_ session: String, active seconds: TimeInterval, provider: AgentProvider = .claude) -> AgentLiveSession {
            AgentLiveSession(id: "/logs/\(session).jsonl", provider: provider, started: now.addingTimeInterval(-600),
                             lastActivity: now.addingTimeInterval(seconds), model: "", project: "vault",
                             tokens: AgentTokens(), cost: 0)
        }
        func tab(_ id: String, _ name: String, _ status: HerdrAgentTab.Status, session: String) -> HerdrAgentTab {
            HerdrAgentTab(id: id, session: session, agent: "claude", status: status, tab: name, workspace: "vault")
        }
        let tabs = [tab("p1", "charts tables", .working, session: "a"), tab("p2", "smooth launch", .working, session: "b"),
                    tab("p3", "mac", .blocked, session: "c"), tab("p4", "notes", .idle, session: "d")]

        let latest = NotchAgentSupport.stripTab(live: [live("a", active: -30), live("b", active: -5)], tabs: Array(tabs.prefix(2)))
        suite.expect(latest?.tab.id == "p2" && latest?.others == 1, "the session active last is named, with the other counted")
        suite.expect(latest.map(NotchAgentSupport.stripTabText) == "smooth launch +1", "others read as +N after the name")

        let waiting = NotchAgentSupport.stripTab(live: [live("a", active: -5)], tabs: tabs)
        suite.expect(waiting?.tab.id == "p3" && waiting?.others == 1,
                     "a tab that needs the person comes first even while another works")

        suite.expect(NotchAgentSupport.stripTab(live: [live("a", active: 0)], tabs: []) == nil,
                     "without herdr the strip names nothing")
        suite.expect(NotchAgentSupport.stripTab(live: [live("a", active: 0, provider: .codex)], tabs: [tab("p1", "x", .working, session: "a")]) == nil,
                     "only Claude sessions are matched to herdr tabs")
        suite.expect(NotchAgentSupport.stripTab(live: [live("z", active: 0)], tabs: [tab("p4", "notes", .idle, session: "d")]) == nil,
                     "an idle tab that isn't the working session is not named")
        suite.expect(NotchAgentSupport.stripTab(live: [live("a", active: 0)], tabs: [tab("p1", "", .working, session: "a")]) == nil,
                     "a tab without a name leaves the strip as it was")

        let busy = tabs + [tab("p5", "done", .done, session: "e"), tab("p6", "more", .working, session: "f"),
                           tab("p7", "lost", .unknown, session: "g")]
        suite.expect(NotchAgentSupport.stripDots(tabs: busy) == [.blocked, .working, .working, .working],
                     "dots put the tab that needs the person first, skip idle ones and stop at four")
        suite.expect(NotchAgentSupport.stripDots(tabs: [tab("p5", "done", .done, session: "e"), tabs[3]]) == [.done],
                     "a finished tab keeps a dot; an idle one has none")
        suite.expect(NotchAgentSupport.stripDotsWidth(0) == 0 && NotchAgentSupport.stripDotsWidth(2) == 20,
                     "no dots take no room")
        suite.expect(NotchAgentSupport.stripWaiting(tabs: busy) == 1 && NotchAgentSupport.stripWaiting(tabs: []) == 0,
                     "the tabs waiting on the person are counted")

        func reading(_ session: String, model: String, context: Int, active seconds: TimeInterval,
                     provider: AgentProvider = .claude) -> AgentLiveSession {
            var value = live(session, active: seconds, provider: provider)
            value.model = model
            value.context = context
            return value
        }
        suite.expect(NotchAgentSupport.contextWindow(model: "claude-opus-5-5", context: 10) == 1_000_000
                     && NotchAgentSupport.contextWindow(model: "claude-haiku-4-5-20251001", context: 150_000) == 200_000
                     && NotchAgentSupport.contextWindow(model: "claude-haiku-4-5-20251001", context: 250_000) == 1_000_000,
                     "Claude 5 models read into a million tokens, others 200K until a request outgrows it")
        let context = NotchAgentSupport.stripContext(live: [
            reading("a", model: "claude-haiku-4-5-20251001", context: 50_000, active: -30),
            reading("b", model: "claude-opus-5-5", context: 630_000, active: -5),
            reading("c", model: "gpt-6", context: 900_000, active: 0, provider: .codex),
        ])
        suite.expect(context == 0.63, "the ring follows the Claude session active last: \(String(describing: context))")
        suite.expect(NotchAgentSupport.stripContext(live: [live("a", active: 0)]) == nil,
                     "no ring before a session's first reply")
    }
}
