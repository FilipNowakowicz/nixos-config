pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// Every running agent session and the tools' usage limits, from scripts/agents.py,
// for the overview's card, the bar's agents panel, its indicator and the peek
// that says when one needs you. While a view is open it asks for everything every
// few seconds; otherwise, only if the indicator or the peek is on, it asks for the
// brief version (states and titles, no transcripts) now and then.
//
// The views come in several styles to choose between (see AgentsCentre's
// Customise): how each looks, what each shows, and what the bar does are kept in
// $XDG_STATE_HOME/quiet-shell/agents.json.
Singleton {
    id: root

    property var info: null
    property real now: Date.now() / 1000
    // Views on screen that want the full detail.
    property int viewers: 0
    function watch(on) { viewers = Math.max(0, viewers + (on ? 1 : -1)); if (on) refresh(); }

    // ---- settings ----------------------------------------------------------
    readonly property var styles: [
        ["compact", "Compact"], ["detailed", "Detailed"], ["pets", "Pets"], ["feed", "Feed"]
    ]
    readonly property var indicators: [["off", "Off"], ["dot", "Dot"], ["count", "Count"], ["face", "Face"]]
    readonly property var peeks: [["off", "Off"], ["waiting", "Needs you"], ["finished", "+ Finished"]]
    // Each `show` key is a piece of information the views can leave out.
    readonly property var shows: [
        ["activity", "Activity"], ["prompt", "Last prompt"], ["said", "Last reply"],
        ["subagents", "Subagents"], ["context", "Context"], ["cost", "Cost"],
        ["meta", "Model · branch"], ["limits", "Limits"], ["finished", "Finished jobs"]
    ]
    property var settings: ({
        style: "detailed",
        card: "compact",
        indicator: "face",
        peek: "waiting",
        show: { activity: true, prompt: true, said: false, subagents: true, context: true,
                cost: true, meta: true, limits: true, finished: false }
    })
    function set(key, value) {
        const next = Object.assign({}, settings);
        next[key] = value;
        settings = next;
        save();
    }
    function shown(key) { return !!settings.show && settings.show[key] === true; }
    function toggleShow(key) {
        const show = Object.assign({}, settings.show);
        show[key] = !show[key];
        set("show", show);
    }
    function cycleStyle() {
        const keys = styles.map(s => s[0]);
        set("style", keys[(keys.indexOf(settings.style) + 1) % keys.length]);
    }
    function save() { if (settingsFile.loaded) settingsFile.setText(JSON.stringify(settings) + "\n"); }
    FileView {
        id: settingsFile
        property bool loaded: false
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/quiet-shell/agents.json"
        printErrors: false
        onLoaded: {
            try {
                const saved = JSON.parse(text());
                const next = Object.assign({}, root.settings, saved);
                next.show = Object.assign({}, root.settings.show, saved.show || {});
                root.settings = next;
            } catch (e) {}
            loaded = true;
        }
        onLoadFailed: loaded = true
    }

    // ---- what the views read ----------------------------------------------
    readonly property var all: info ? info.sessions : []
    // Background jobs that have finished are left out unless asked for.
    readonly property var sessions: all.filter(s => s.state !== "done" || shown("finished"))
    readonly property int finishedCount: all.filter(s => s.state === "done").length
    readonly property var waitingSessions: all.filter(s => s.state === "waiting")
    readonly property int working: all.filter(s => s.state === "working").length
    readonly property int live: all.filter(s => s.state !== "done").length
    // The one the bar speaks for: one waiting on you, else one working, else any.
    readonly property var top: all.find(s => s.state === "waiting") ?? all.find(s => s.state === "working") ?? all.find(s => s.state !== "done") ?? null
    readonly property var tools: info ? [["Claude", "claude"], ["Codex", "codex"]].filter(t => hasLimits(info[t[1]])) : []
    function hasLimits(tool) { return !!tool && tool.paid !== false && (tool.five_hour !== null || tool.week !== null); }

    // Sessions that went from working to idle a moment ago, for the peek.
    property var finishedAt: ({})
    property var lastStates: ({})
    readonly property var justFinished: all.filter(s => finishedAt[s.id] && now - finishedAt[s.id] < 12)
    onAllChanged: {
        const states = {}, done = Object.assign({}, finishedAt);
        for (const s of all) {
            states[s.id] = s.state;
            if (lastStates[s.id] === "working" && (s.state === "idle" || s.state === "done"))
                done[s.id] = now;
        }
        lastStates = states;
        finishedAt = done;
    }

    // ---- polling -----------------------------------------------------------
    readonly property bool full: viewers > 0
    readonly property bool wanted: full || settings.indicator !== "off" || settings.peek !== "off"
    readonly property var command: {
        const custom = Quickshell.env("QUIET_AGENTS");
        if (custom)
            return ["sh", "-c", custom + (full ? "" : " --brief")];
        const script = Qt.resolvedUrl("scripts/agents.py").toString().replace("file://", "");
        return full ? ["python3", script] : ["python3", script, "--brief"];
    }
    property string lastText: ""
    property real polled: 0
    function refresh() {
        polled = Date.now();
        now = polled / 1000;
        if (!probe.running)
            probe.running = true;
    }
    Process {
        id: probe
        command: root.command
        stdout: StdioCollector {
            onStreamFinished: {
                // The same answer again changes nothing, so nothing is redrawn.
                if (text === root.lastText)
                    return;
                root.lastText = text;
                try {
                    const next = JSON.parse(text);
                    // A brief answer knows nothing of activity; keep what the last
                    // full one said for each session rather than blanking it.
                    if (!root.full && root.info) {
                        const old = {};
                        for (const s of root.info.sessions) old[s.id] = s;
                        next.sessions = next.sessions.map(s => old[s.id] ? Object.assign({}, old[s.id], s, {
                            subagents: old[s.id].subagents, terminal: old[s.id].terminal }) : s);
                        for (const t of ["claude", "codex"])
                            for (const w of ["five_hour", "week"])
                                if (next[t][w] && root.info[t] && root.info[t][w])
                                    next[t][w].runs_out = root.info[t][w].runs_out;
                    }
                    root.info = next;
                } catch (e) {
                    console.warn("quiet-shell: bad agents output", e);
                }
            }
        }
    }
    // One steady tick that asks when an answer is due: every 4 seconds while a
    // view is open, every 10 otherwise. A Timer whose interval and running both
    // followed the views stopped firing once they had changed a few times.
    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: if (root.wanted && Date.now() - root.polled >= (root.full ? 3900 : 9900)) root.refresh()
    }
    Component.onCompleted: if (wanted) refresh()
    // Faces blink and working ones fidget; one clock for all of them, running only
    // while a face is on screen, so the shell sleeps otherwise.
    property int frame: 0
    readonly property bool animating: !Theme.reducedMotion && (viewers > 0
        || settings.indicator === "face" && Ui.topShown && live > 0
        || settings.peek !== "off" && !Ui.topShown && (waitingSessions.length > 0 || justFinished.length > 0))
    Timer {
        interval: 700
        running: root.animating
        repeat: true
        onTriggered: { root.frame++; root.now = Date.now() / 1000; }
    }

    // ---- actions -------------------------------------------------------------
    // The kitty window first (the right tab inside kitty), then the desktop window
    // that kitty process owns, once the shell is out of the way.
    function jump(session) {
        const t = session ? session.terminal : null;
        if (!t)
            return;
        Quickshell.execDetached(["kitty", "@", "--to", "unix:" + t.socket, "focus-window", "--match", "id:" + t.window]);
        // One kitty can own several desktop windows: the one showing this session's title.
        const owned = Hyprland.toplevels.values.filter(x => x.lastIpcObject && x.lastIpcObject.pid === t.kitty);
        const owner = owned.find(x => x.title === t.title) ?? owned[0];
        Ui.close();
        if (owner)
            Dockable.revealAfterClose(owner);
    }
    // The switch is a file named for the session's process, which scripts/resume.py
    // looks for and removes once that process is gone.
    function setResume(session, on) {
        if (!session.key)
            return;
        Quickshell.execDetached(["sh", "-c",
            'dir="${XDG_STATE_HOME:-$HOME/.local/state}/agent-usage/resume"; '
            + 'if [ "$2" = on ]; then mkdir -p "$dir" && : >"$dir/$1"; else rm -f "$dir/$1"; fi',
            "sh", session.key, on ? "on" : "off"]);
        soon.restart();
    }
    Timer { id: soon; interval: 1500; onTriggered: root.refresh() }

    // Customise in the agents panel is open; kept here so IPC can open it too.
    property bool customising: false

    // ---- words ---------------------------------------------------------------
    // Claude Code's registry says why a session waits in its own words.
    readonly property var waitReasons: ({
        "dialog open": "a prompt is open", "input needed": "a question for you",
        "sandbox request": "sandbox access", "worker request": "a helper's request",
        "goal proposal": "a proposed goal"
    })
    function waitText(s) { return s.waiting ? (waitReasons[s.waiting] || s.waiting) : ""; }
    function until(at) {
        if (!at)
            return "";
        return span(at - now);
    }
    function ago(at) { return at ? span(now - at) : ""; }
    function span(seconds) {
        const minutes = Math.max(0, Math.round(seconds / 60));
        if (minutes < 1)
            return "now";
        if (minutes < 60)
            return minutes + "m";
        if (minutes < 24 * 60)
            return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m";
        return Math.floor(minutes / 1440) + "d " + Math.floor(minutes % 1440 / 60) + "h";
    }
    function clock(at) { return at ? Qt.formatTime(new Date(at * 1000), "HH:mm") : ""; }
    function tokens(n) {
        if (n === null || n === undefined)
            return "";
        if (n >= 1e6)
            return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1).replace(/\.0$/, "") + "M";
        if (n >= 1000)
            return Math.round(n / 1000) + "k";
        return String(n);
    }
    function money(usd) {
        if (usd === null || usd === undefined)
            return "";
        return "$" + (usd >= 100 ? Math.round(usd) : usd.toFixed(2));
    }
    function title(s) {
        return s.name || s.project || "~";
    }
    function contextText(s) {
        if (s.context === null || s.context === undefined)
            return "";
        const parts = Math.round(s.context) + "%";
        return s.tokens && s.context_size ? parts + " · " + tokens(s.tokens) + "/" + tokens(s.context_size) : "ctx " + parts;
    }
    // A few words for how a session stands, for the end of its row.
    function stateText(s) {
        if (s.limited !== null && s.limited !== undefined)
            return (s.resume ? "resumes " : "limit · back ") + (s.limited ? "in " + until(s.limited) : "now");
        switch (s.state) {
        case "waiting": return "needs you";
        case "working": return "working" + (s.asked ? " " + ago(s.asked) : "");
        case "done": return s.job && s.job.state && s.job.state !== "done" ? s.job.state : "finished";
        default: return "idle " + ago(s.since || s.at);
        }
    }
    // What it is doing, as one line: "Edit Top.qml", "nix build .#main-ci".
    readonly property var verbs: ({
        read: "Reading", edit: "Editing", run: "Running", web: "Browsing", delegate: "Delegating",
        plan: "Planning", ask: "Asking", skill: "Using skill", tool: "Using", think: "Thinking", write: "Wrote"
    })
    function doingText(s) {
        if (s.state === "waiting")
            return s.waiting ? "Waiting on " + waitText(s) : "Waiting for you";
        if (s.background && s.job && s.job.detail && s.state !== "working")
            return s.job.detail;
        const d = s.doing;
        if (!d)
            return "";
        if (d.kind === "write")
            return s.state === "working" ? "Writing" : d.text;
        if (d.kind === "think")
            return s.state === "working" ? "Thinking" : "";
        const what = d.text || d.tool;
        if (d.kind === "tool" || d.kind === "skill")
            return d.tool.replace(/^mcp__[^_]+(_[^_]+)*__/, "") + (d.text ? " · " + d.text : "");
        return verbs[d.kind] + " " + what;
    }
    readonly property var kindIcons: ({
        read: "search", edit: "notebook-pen", run: "terminal", web: "globe", delegate: "rocket",
        plan: "layout-grid", ask: "bell-ring", skill: "zap", tool: "hammer", think: "clock", write: "check"
    })
    function kindIcon(s) {
        if (s.state === "waiting")
            return "bell-ring";
        return s.doing ? (kindIcons[s.doing.kind] || "hammer") : "terminal";
    }

    // ---- faces ---------------------------------------------------------------
    // Each session gets a creature of its own (from its id, so it keeps it), whose
    // face says what it is up to. Plain text, so it sits in a line of words.
    readonly property var creatures: [["ʕ", "ʔ"], ["(=", "=)"], ["(", ")"], ["{", "}"], ["[", "]"], ["<", ">"]]
    readonly property var faces: ({
        think: ["•_•", "•_•", "-_•", "•_•"],
        read: ["◔_◔", "◑_◑", "◕_◕", "◑_◑"],
        edit: ["ᵔᴗᵔ", "ᵔᴗᵔ", "-ᴗᵔ", "ᵔᴗᵔ"],
        run: ["ò_ó", "ó_ò", "ò_ó", "ó_ò"],
        web: ["⊙_⊙", "⊙.⊙", "⊙_⊙", "⊙ˍ⊙"],
        delegate: ["•ᴗ•", "•ᴗ•", "•ᴗ-", "•ᴗ•"],
        plan: ["¬_¬", "¬‿¬", "¬_¬", "¬‿¬"],
        ask: ["°o°", "°O°", "°o°", "°O°"],
        skill: ["✧ᴗ✧", "•ᴗ•", "✧ᴗ✧", "•ᴗ•"],
        tool: ["•_•", "•-•", "•_•", "•-•"],
        write: ["•‿•", "•‿•", "-‿-", "•‿•"],
        waiting: ["°□°", "°□°", "°o°", "°□°"],
        idle: ["•‿•", "•‿•", "•‿•", "-‿-", "•‿•", "•‿•"],
        sleep: ["-_-", "-_-", "-ω-", "-_-"],
        done: ["^ᴗ^", "^ᴗ^", "^‿^", "^ᴗ^"],
        limited: ["×_×", "×_×", "x_x", "×_×"],
        full: ["@_@", "@_@", "@.@", "@_@"]
    })
    function hash(text) {
        let h = 0;
        for (let i = 0; i < text.length; i++)
            h = (h * 31 + text.charCodeAt(i)) | 0;
        return Math.abs(h);
    }
    function mood(s) {
        if (s.limited !== null && s.limited !== undefined)
            return "limited";
        if (s.state === "waiting")
            return "waiting";
        if (s.state === "done")
            return "done";
        if (s.state === "working") {
            if (s.context !== null && s.context !== undefined && s.context >= 85)
                return "full";
            return s.doing ? s.doing.kind : "think";
        }
        return now - (s.since || s.at) > 1800 ? "sleep" : "idle";
    }
    function face(s, still) {
        const c = creatures[hash(s.id || "") % creatures.length];
        const frames = faces[mood(s)] || faces.idle;
        // Each creature on its own beat, so a row of them doesn't move in step.
        const f = still || Theme.reducedMotion ? 0 : (frame + hash(s.id || "")) % frames.length;
        return c[0] + frames[f] + c[1];
    }
    // What a creature would say, in a word or two after its name.
    function narrate(s) {
        switch (mood(s)) {
        case "limited": return "is out of juice" + (s.limited ? " until " + clock(s.limited) : "");
        case "waiting": return "needs you" + (s.waiting ? " · " + waitText(s) : "");
        case "done": return "is done" + (s.job && s.job.detail ? ": " + s.job.detail : "");
        case "sleep": return "is dozing · " + ago(s.since || s.at);
        case "idle": return "is waiting for a prompt";
        case "full": return "is stuffed (" + Math.round(s.context) + "% context)";
        }
        const d = s.doing;
        const what = d && d.text ? d.text : "";
        switch (d ? d.kind : "think") {
        case "read": return "is reading " + what;
        case "edit": return "is editing " + what;
        case "run": return "is running " + what;
        case "web": return "is looking online: " + what;
        case "delegate": return "sent a helper: " + what;
        case "plan": return "is making a plan";
        case "ask": return "has a question";
        case "skill": return "is using a skill " + what;
        case "write": return "is writing";
        case "tool": return "is using " + (d.tool || "a tool").replace(/^mcp__[^_]+(_[^_]+)*__/, "");
        default: return "is thinking" + ".".repeat(1 + frame % 3);
        }
    }
    // Context as a little bar of blocks, for a line of text.
    function meter(percent, cells) {
        const n = cells || 8;
        const filled = Math.max(0, Math.min(n, Math.round((percent || 0) / 100 * n)));
        return "▰".repeat(filled) + "▱".repeat(n - filled);
    }
}
