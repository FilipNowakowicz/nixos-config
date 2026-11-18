pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// Driving agent sessions' terminals, for the overview's agents card and the agent
// board. scripts/agents.py names the kitty window each session runs in (its socket
// and window id, see home/files/kitty/kitty.conf); these act on it.
//
// Agent Desktop's events (`agent-desktop events --follow`). A request to take a
// private session (for example to sign in) becomes a banner whose buttons run the
// command the event carries, as printed for a terminal. Nothing is taken without a
// click, and the banner goes away once the request is withdrawn or taken.
// Requests to use your own screen are not shown here: the agent's client asks for
// those, or Agent Desktop sends its own notification.
Singleton {
    id: root

    // Session -> its notice, while the request waits for the person.
    property var waiting: ({})
    readonly property int requests: Object.keys(waiting).length
    readonly property var command: {
        const custom = Quickshell.env("QUIET_AGENT_EVENTS");
        return custom ? ["sh", "-c", custom] : ["agent-desktop", "events", "--follow"];
    }

    // The kitty window first (the right tab inside kitty), then the desktop window
    // that kitty process owns, once the shell's surfaces are out of the way.
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
    // Types text into a session and presses Enter. Sent through stdin, so kitty
    // types it exactly and reads no escapes in it; a bracketed paste keeps the
    // agent from taking it for keystrokes, and the Enter after it submits.
    function reply(session, text) {
        const t = session ? session.terminal : null;
        if (!t || text.trim() === "")
            return;
        Quickshell.execDetached(["sh", "-c",
            'printf %s "$3" | kitty @ --to "unix:$1" send-text --match "id:$2" --bracketed-paste auto --stdin'
            + ' && sleep 0.1 && kitty @ --to "unix:$1" send-key --match "id:$2" enter',
            "sh", t.socket, String(t.window), text]);
    }
    // One key, as kitty names it: "1" picks the first answer of a prompt, "escape"
    // interrupts the agent.
    function press(session, key) {
        const t = session ? session.terminal : null;
        if (!t)
            return;
        Quickshell.execDetached(["kitty", "@", "--to", "unix:" + t.socket, "send-key", "--match", "id:" + t.window, key]);
    }

    function run(line) {
        if (line)
            Quickshell.execDetached(["sh", "-c", line]);
    }
    function wait(key, entry) {
        const next = Object.assign({}, waiting);
        next[key] = entry;
        waiting = next;
    }
    function settle(key) {
        const entry = waiting[key];
        if (!entry)
            return;
        Notify.remove(entry);
        const next = Object.assign({}, waiting);
        delete next[key];
        waiting = next;
    }
    function handle(event) {
        const session = event.session;
        switch (event.event) {
        case "human_requested": {
            settle(session);
            const actions = [{ text: "Take control", invoke: () => root.run(event.take_command) }];
            if (event.login)
                actions.push({ text: "Paste and take", invoke: () => root.run(event.paste_command) });
            wait(session, Notify.post(event.login ? "An agent needs you to sign in" : "An agent needs you", event.reason || "", true, "", actions, "Agent Desktop"));
            break;
        }
        case "human_withdrawn":
        case "control_taken":
        case "session_stopped":
            settle(session);
            break;
        case "session_failed":
            settle(session);
            Notify.post("An agent desktop failed", event.error || "", false, "", [], "Agent Desktop");
            break;
        case "control_returned":
            if (event.browser && event.browser.restarted === false)
                Notify.post("The agent's browser did not restart", event.browser.error || "", false, "", [], "Agent Desktop");
            break;
        }
    }

    Process {
        id: stream
        running: true
        command: root.command
        stdout: SplitParser {
            onRead: line => {
                try {
                    root.handle(JSON.parse(line));
                } catch (e) {
                    // Not an event line; the stream's own errors stay out of the shell.
                }
            }
        }
        // Without Agent Desktop the command fails at once; look again now and then.
        // The stream starts again with what is live, so forget what it said before:
        // a request settled while it was down would otherwise stay up.
        onExited: {
            for (const key of Object.keys(root.waiting))
                root.settle(key);
            retry.restart();
        }
    }
    Timer { id: retry; interval: 30000; onTriggered: stream.running = true }
}
