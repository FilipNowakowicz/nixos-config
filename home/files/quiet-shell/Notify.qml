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
            n.source.dismiss();
        items = [];
        banner = null;
    }
    function remove(entry) {
        entry.source.dismiss();
        items = items.filter(i => i !== entry);
        if (banner === entry)
            banner = null;
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
