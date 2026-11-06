pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Notifications

// Keeps a history of notifications. Focus silences banners, not the history.
Singleton {
    id: root
    property var items: []
    property var banner: null

    function clear() {
        for (const n of items)
            if (n.source) n.source.dismiss();
        items = [];
        banner = null;
    }
    function remove(entry) {
        if (entry.source) entry.source.dismiss();
        items = items.filter(i => i !== entry);
        if (banner === entry)
            banner = null;
    }

    // For the shell's own messages. An urgent one still shows during Focus.
    function post(title, body, urgent) {
        const entry = { source: null, app: "System", title, body, at: new Date() };
        items = [entry].concat(items);
        if (urgent || !Sys.focusMode) {
            banner = entry;
            timer.restart();
        }
    }

    NotificationServer {
        keepOnReload: false
        actionsSupported: true
        imageSupported: true
        onNotification: n => {
            n.tracked = true;
            const entry = { source: n, app: n.appName, title: n.summary, body: n.body, at: new Date() };
            root.items = [entry].concat(root.items);
            if (!Sys.focusMode || n.urgency === NotificationUrgency.Critical) {
                root.banner = entry;
                timer.restart();
            }
        }
    }
    Timer { id: timer; interval: 4500; onTriggered: root.banner = null }
}
