pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Notifications

// Keeps a history of notifications. Focus silences banners, not the history.
Singleton {
    id: root
    property var items: []
    property var banner: null
    // A warning that stays up until it is dismissed. A newer banner covers it for
    // its few seconds, then it comes back.
    property var sticky: null
    readonly property var shown: banner || sticky
    // A card's entry arrives through a Repeater's modelData, which is a copy, not
    // the object in `items`. So entries are matched by this key, never identity.
    property int lastKey: 0
    function same(a, b) { return !!a && !!b && a.key === b.key; }

    function clear() {
        const previous = items;
        items = [];
        banner = null;
        sticky = null;
        openApps = [];
        timer.stop();
        for (const n of previous)
            if (n.source) n.source.dismiss();
    }
    function remove(entry) {
        const original = items.find(i => same(i, entry));
        items = items.filter(i => !same(i, entry));
        if (same(banner, entry))
            banner = null;
        if (same(sticky, entry))
            sticky = null;
        if (original && original.source) original.source.dismiss();
    }

    function stick(entry) {
        sticky = entry;
        banner = null;
        timer.stop();
    }

    // The app decides what happens next, so the notification has done its job.
    function invoke(entry, action) {
        items = items.filter(i => !same(i, entry));
        if (same(banner, entry))
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
            // fold marks the opened app's first card, which carries "Show less".
            if (openApps.includes(app))
                list.forEach((entry, i) => out.push({ entry, more: 0, fold: i === 0 && list.length > 1 }));
            else
                out.push({ entry: list[0], more: list.length - 1, fold: false });
        }
        return out;
    }

    // Stays up while the pointer is on it, so it can be read and clicked.
    function holdBanner(held) {
        if (held) timer.stop();
        else if (banner) timer.restart();
    }

    // For the shell's own messages. An urgent one still shows during Focus.
    // `actions` are buttons, each { text, invoke }; `app` names the sender.
    function post(title, body, urgent, image, actions, app) {
        const entry = { key: ++lastKey, source: null, system: true, app: app || "System", title, body, at: new Date(), image: image || "", actions: actions || [] };
        items = [entry].concat(items);
        if (urgent || !Sys.focusMode) {
            banner = entry;
            timer.restart();
        }
        return entry;
    }

    NotificationServer {
        keepOnReload: false
        actionsSupported: true
        imageSupported: true
        onNotification: n => {
            n.tracked = true;
            const entry = { key: ++root.lastKey, source: n, app: n.appName, icon: n.appIcon, title: n.summary, body: n.body, at: new Date() };
            // Apps can close their own notifications. Quickshell destroys the
            // object after this signal; retain the history without a dead QObject
            // whose dismiss()/actions would throw when the card is used later.
            n.closed.connect(() => {
                const saved = Object.assign({}, entry, { source: null });
                root.items = root.items.map(i => root.same(i, entry) ? saved : i);
                if (root.same(root.banner, entry))
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
