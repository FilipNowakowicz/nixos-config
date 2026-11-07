pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// What's running, by app. Identity is the desktop entry.
// Hyprland has no minimise, so a minimised window lives on a hidden special workspace.
Singleton {
    id: root
    readonly property string hiddenWorkspace: "special:minimized"

    function entry(id) {
        return DesktopEntries.heuristicLookup(id);
    }
    function nameOf(id) {
        const e = entry(id);
        return e ? e.name : id.charAt(0).toUpperCase() + id.slice(1);
    }
    // Reads the entries so these update once they load, which happens after startup.
    function names(toplevels) {
        DesktopEntries.applications.values;
        const out = [];
        for (const t of toplevels) {
            const id = t.wayland ? t.wayland.appId : "";
            const name = id ? nameOf(id) : "";
            if (name && !out.includes(name))
                out.push(name);
        }
        return out;
    }
    function iconOf(id) {
        const e = entry(id);
        return e ? e.icon : id;
    }

    // Windows, last focused first. Hyprland doesn't expose this order.
    property var recent: []
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            const t = ToplevelManager.activeToplevel;
            if (t)
                root.recent = [t].concat(root.recent.filter(x => x !== t && ToplevelManager.toplevels.values.includes(x)));
        }
    }
    readonly property var recentWindows: {
        const rank = t => {
            const at = recent.indexOf(t.wayland);
            return at < 0 ? recent.length : at;
        };
        return Hyprland.toplevels.values.slice().sort((a, b) => rank(a) - rank(b));
    }

    // Always ten, in the order of SUPER+1 to SUPER+0, so a dot's place means something.
    readonly property var desks: {
        const named = {};
        for (const ws of Hyprland.workspaces.values)
            named[ws.id] = ws;
        return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(id => {
            const ws = named[id];
            return { id, apps: ws ? names(ws.toplevels.values) : [] };
        });
    }

    function isHidden(t) {
        return !!t.workspace && t.workspace.name === hiddenWorkspace;
    }
    function isActive(t) {
        return !!t.wayland && t.wayland === ToplevelManager.activeToplevel;
    }
    function here(t) {
        return !!t.workspace && t.workspace === Hyprland.focusedWorkspace;
    }
    function move(t, workspace, follow) {
        Hyprland.dispatch("hl.dsp.window.move({workspace=" + workspace + ",window=\"address:0x" + t.address + "\",follow=" + follow + "})");
    }
    function minimize(t) {
        move(t, "\"" + hiddenWorkspace + "\"", false);
    }
    // Comes back to the desktop you are on, not the one it left.
    function restore(t) {
        move(t, Hyprland.focusedWorkspace.id, true);
    }
    function reveal(t) {
        if (isHidden(t)) restore(t);
        else t.wayland.activate();
    }
    // While a surface holds the keyboard, closing it hands focus back to the old window
    // and undoes the switch. So surfaces close first, and the switch follows.
    property var pendingReveal: null
    function revealAfterClose(t) {
        pendingReveal = t;
        revealTimer.restart();
    }
    Timer {
        id: revealTimer
        interval: 60
        onTriggered: if (root.pendingReveal) root.reveal(root.pendingReveal)
    }
    function revealWayland(toplevel) {
        const t = Hyprland.toplevels.values.find(x => x.wayland === toplevel);
        if (t) revealAfterClose(t);
        else toplevel.activate();
    }
    function launch(app) {
        const e = entry(app.id);
        if (e) e.execute();
    }
    function closeAll(app) {
        for (const t of app.windows)
            Hyprland.dispatch("hl.dsp.window.close({window=\"address:0x" + t.address + "\"})");
    }
    function click(app) {
        const hidden = app.windows.find(isHidden);
        if (hidden) {
            restore(hidden);
            return;
        }
        const at = app.windows.findIndex(isActive);
        if (at >= 0 && app.windows.length === 1)
            minimize(app.windows[0]);
        else
            app.windows[(at + 1) % app.windows.length].wayland.activate();
    }

    readonly property var apps: {
        DesktopEntries.applications.values;
        const out = [];
        for (const t of Hyprland.toplevels.values) {
            const id = t.wayland ? t.wayland.appId : "";
            if (!id) continue;
            let app = out.find(a => a.id === id.toLowerCase());
            if (!app) {
                const e = entry(id);
                app = { id: id.toLowerCase(), name: nameOf(id), icon: e ? e.icon : id, windows: [] };
                out.push(app);
            }
            app.windows.push(t);
        }
        return out;
    }
}
