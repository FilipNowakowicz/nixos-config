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
        const previous = items;
        items = [];
        banner = null;
        openApps = [];
        timer.stop();
        for (const n of previous)
            if (n.source) n.source.dismiss();
    }
    function remove(entry) {
        items = items.filter(i => i !== entry);
        if (banner === entry)
            banner = null;
        if (entry.source) entry.source.dismiss();
    }

    // The app decides what happens next, so the notification has done its job.
    function invoke(entry, action) {
        items = items.filter(i => i !== entry);
        if (banner === entry)
            banner = null;
        action.invoke();
    }

    // One card per app, newest first, unless that app has been opened out.
    property var openApps: []
    function toggleApp(app) {
        openApps = openApps.includes(app) ? openApps.filter(a => a !== app) : openApps.concat([app]);
    }
    readonly property var groups: {
        const seen = new Map();
        for (const item of items) {
            if (!seen.has(item.app))
                seen.set(item.app, []);
            seen.get(item.app).push(item);
        }
        const out = [];
        for (const [app, list] of seen) {
            if (openApps.includes(app))
                list.forEach(entry => out.push({ entry, more: 0 }));
            else
                out.push({ entry: list[0], more: list.length - 1 });
        }
        return out;
    }

    // Stays up while the pointer is on it, so it can be read and clicked.
    function holdBanner(held) {
        if (held) timer.stop();
        else if (banner) timer.restart();
    }

    // For the shell's own messages. An urgent one still shows during Focus.
    function post(title, body, urgent, image) {
        const entry = { source: null, app: "System", title, body, at: new Date(), image: image || "" };
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
            // Apps can close their own notifications. Quickshell destroys the
            // object after this signal; retain the history without a dead QObject
            // whose dismiss()/actions would throw when the card is used later.
            n.closed.connect(() => {
                const saved = Object.assign({}, entry, { source: null });
                root.items = root.items.map(i => i === entry ? saved : i);
                if (root.banner === entry)
                    root.banner = saved;
            });
            root.items = [entry].concat(root.items);
            if (!Sys.focusMode || n.urgency === NotificationUrgency.Critical) {
                root.banner = entry;
                timer.restart();
            }
        }
    }
    Timer { id: timer; interval: 4500; onTriggered: root.banner = null }
}
