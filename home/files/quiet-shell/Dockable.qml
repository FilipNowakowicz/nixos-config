pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Wayland

// Pinned apps and whatever else is running. Identity is the desktop entry.
Singleton {
    id: root
    property var pinnedIds: ["firefox", "kitty", "thunar", "discord", "spotify"]

    function matching(id) {
        return ToplevelManager.toplevels.values.filter(t => t.appId.toLowerCase() === id.toLowerCase());
    }
    function make(id) {
        const entry = DesktopEntries.heuristicLookup(id);
        return {
            id,
            name: entry ? entry.name : id.charAt(0).toUpperCase() + id.slice(1),
            icon: entry ? entry.icon : id,
            launch() {
                const open = root.matching(id);
                if (open.length) open[0].activate();
                else if (entry) entry.execute();
            }
        };
    }
    readonly property var pinned: pinnedIds.map(make)
    readonly property var running: {
        const seen = new Set(pinnedIds.map(p => p.toLowerCase()));
        const out = [];
        for (const t of ToplevelManager.toplevels.values) {
            const id = t.appId.toLowerCase();
            if (id && !seen.has(id)) {
                seen.add(id);
                out.push(make(t.appId));
            }
        }
        return out;
    }
}
