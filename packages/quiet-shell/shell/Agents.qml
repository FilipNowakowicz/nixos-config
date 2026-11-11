pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Agent Desktop's events (`agent-desktop events --follow`). A request for the person
// becomes a banner whose buttons run the command the event carries, as printed for
// a terminal. Nothing is answered without a click, and the banner goes away once the
// request is answered, withdrawn or taken.
Singleton {
    id: root

    // Session or host request -> its notice, while it waits for the person.
    property var waiting: ({})
    readonly property int requests: Object.keys(waiting).length
    readonly property var command: {
        const custom = Quickshell.env("QUIET_AGENT_EVENTS");
        return custom ? ["sh", "-c", custom] : ["agent-desktop", "events", "--follow"];
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
        case "host_requested":
            settle("host:" + event.request);
            wait("host:" + event.request, Notify.post("An agent asks to use your screen", (event.reason || "") + (event.minutes ? " · " + event.minutes + " min" : ""), true, "", [
                { text: "Allow", invoke: () => root.run(event.approve_command) },
                { text: "Decline", invoke: () => root.run(event.deny_command) }
            ], "Agent Desktop"));
            break;
        case "host_answered":
        case "host_expired":
            settle("host:" + event.request);
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
        onExited: retry.restart()
    }
    Timer { id: retry; interval: 30000; onTriggered: stream.running = true }
}
