import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// One layer surface per screen holds everything. The input mask lets clicks through
// except on what is visible, and covers the screen while a panel is open so a click
// anywhere dismisses it.
PanelWindow {
    id: win

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "quiet-shell"
    WlrLayershell.layer: WlrLayer.Overlay
    // The switcher leaves the keyboard with Hyprland. Handing it back after a switch
    // refocused the window the switch had just left.
    WlrLayershell.keyboardFocus: Ui.blocking && !Ui.switcher ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property bool focused: Ui.focusedScreen === "" || !screen || Ui.focusedScreen === screen.name
    readonly property bool fullscreenApp: {
        const t = ToplevelManager.activeToplevel;
        return !!t && t.fullscreen;
    }

    mask: Region {
        Region { item: Ui.blocking && win.focused ? root : null }
        Region { item: win.fullscreenApp ? null : hotTop }
        Region { item: win.fullscreenApp ? null : hotBottom }
        Region { item: Notify.banner && win.focused ? banner : null }
    }

    Item {
        id: root
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: Ui.back()
        Keys.onPressed: event => {
            if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                return;
            if (Ui.panel === "controls" && Ui.detail === "")
                event.accepted = controls.pressLetter(event.text.toLowerCase());
            else if (Ui.panel === "controls")
                event.accepted = controls.pressDetailKey(event);
            else if (Ui.panel === "system")
                event.accepted = menus.pressLetter(event.text.toLowerCase());
            else if (Ui.panel === "notifications")
                event.accepted = notifications.pressKey(event.text);
            else if (Ui.screenshot)
                event.accepted = shot.pressKey(event.text);
        }
        Keys.onReturnPressed: event => {
            if (Ui.switcher) Ui.commitSwitcher();
            else if (Ui.overview) Ui.close();
            else event.accepted = false;
        }
        Keys.onReleased: event => {
            if (Ui.switcher && (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta))
                Ui.commitSwitcher();
        }
        Keys.onTabPressed: event => {
            const forward = !(event.modifiers & Qt.ShiftModifier);
            if (Ui.switcher) Ui.stepSwitcher(1);
            else if (overview.item) overview.item.step(forward ? 1 : -1);
            else if (Ui.panel === "controls") win.stepFocus(forward);
            else event.accepted = false;
        }
        Keys.onBacktabPressed: event => {
            if (overview.item) overview.item.step(-1);
            else if (Ui.panel === "controls") win.stepFocus(false);
            else event.accepted = false;
        }

        MouseArea {
            anchors.fill: parent
            enabled: Ui.blocking
            onClicked: Ui.close()
        }

        // Hot edges are 2px while hidden and grow once revealed, so the pointer can
        // travel from wherever it hit the edge to a capsule without the bar hiding.
        MouseArea {
            id: hotTop
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: Ui.topShown ? 44 : 2
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onEntered: { Hyprland.refreshMonitors(); hideTop.stop(); Ui.topRevealed = true; }
        }
        MouseArea {
            id: hotBottom
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
            width: parent.width * 0.5
            height: Ui.dockRevealed ? 84 : 2
            enabled: Dockable.apps.length > 0
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onEntered: { Hyprland.refreshMonitors(); hideDock.stop(); Ui.dockRevealed = true; }
        }

        // Built only while open: live window capture should cost nothing at rest.
        Loader {
            id: overview
            anchors.fill: parent
            active: (Ui.overview || opacity > 0) && win.focused
            opacity: Ui.overview ? 1 : 0
            scale: Ui.overview ? 1 : 1.04
            Behavior on opacity { NumberAnimation { duration: Theme.motion } }
            Behavior on scale { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
            sourceComponent: Overview {}
        }

        Top { id: top; anchors.fill: parent; visible: win.focused || Ui.pinned }

        ControlCentre {
            id: controls
            visible: (Ui.panel === "controls" || opacity > 0) && win.focused
            x: parent.width - width - 8
            y: Ui.panel === "controls" ? 42 : 34
            opacity: Ui.panel === "controls" ? 1 : 0
            Behavior on y { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: Theme.motion } }
            MouseArea { z: -1; anchors.fill: parent }
        }

        NotificationCentre {
            id: notifications
            visible: (Ui.panel === "notifications" || opacity > 0) && win.focused
            x: parent.width - width - 8 + (Ui.panel === "notifications" ? 0 : 20)
            y: 42
            opacity: Ui.panel === "notifications" ? 1 : 0
            Behavior on x { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: Theme.motion } }
        }

        Menus { id: menus; anchors.fill: parent; visible: win.focused }

        Banner { id: banner; visible: win.focused && Ui.panel === "" && !Ui.overview }

        DockMenu {
            visible: Ui.panel === "dock" && win.focused
            x: Math.min(parent.width - width - 8, Math.max(8, (Ui.dockMenu ? Ui.dockMenu.x : 0) - width / 2))
            y: parent.height - height - 82
        }

        Spotlight { visible: Ui.spotlight && win.focused; anchors.horizontalCenter: parent.horizontalCenter; y: parent.height * 0.2 }

        Switcher {
            visible: Ui.switcher && win.focused
            anchors.centerIn: parent
        }

        DeskHud {
            visible: opacity > 0 && win.focused
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.82 + 4
        }

        AreaDrag {
            anchors.fill: parent
            visible: Ui.screenshot && win.focused
            origin: win.screen ? Qt.point(win.screen.x, win.screen.y) : Qt.point(0, 0)
        }

        Screenshot {
            id: shot
            visible: Ui.screenshot && win.focused
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.82
        }

        Shortcuts {
            visible: Ui.cheatSheet && win.focused
            anchors.centerIn: parent
        }

        Hud {
            visible: opacity > 0 && win.focused
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.82
        }

        Confirm { visible: Ui.confirm !== null && win.focused; z: 10 }

        AuthPrompt { visible: Ui.auth !== null && win.focused; z: 11 }

        Dock {
            id: dock
            anchors.horizontalCenter: parent.horizontalCenter
            visible: win.focused && Dockable.apps.length > 0
            y: parent.height - (Ui.dockRevealed || Ui.overview ? height + 6 : -10)
            Behavior on y { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
        }
    }

    // The Tab order covers the whole window, so keep it inside the panel rather than
    // walking through the bar's desktop dots to get there.
    function stepFocus(forward) {
        let item = root.Window.activeFocusItem;
        for (let hops = 0; item && hops < 200; hops++) {
            item = item.nextItemInFocusChain(forward);
            for (let up = item; up; up = up.parent) {
                if (up === controls) {
                    item.forceActiveFocus(Qt.TabFocusReason);
                    return;
                }
            }
        }
    }

    Connections {
        target: Ui
        function onRefocus() { root.forceActiveFocus(); }
        // A hidden control can't hand the keyboard back, and the letters need it.
        function onPanelChanged() { root.forceActiveFocus(); }
        function onDetailChanged() { root.forceActiveFocus(); }
    }
    Timer {
        id: hideTop
        interval: 260
        onTriggered: if (!top.hovered && !hotTop.containsMouse && !Ui.dragging) Ui.topRevealed = false
    }
    Connections {
        target: top
        function onHoveredChanged() { if (!top.hovered) hideTop.restart(); else hideTop.stop(); }
    }
    Connections {
        target: hotTop
        function onContainsMouseChanged() { if (!hotTop.containsMouse) hideTop.restart(); }
    }
    Timer {
        id: hideDock
        interval: 300
        onTriggered: if (!dock.hovered && !hotBottom.containsMouse && Ui.panel !== "dock") Ui.dockRevealed = false
    }
    Connections {
        target: dock
        function onHoveredChanged() { if (!dock.hovered) hideDock.restart(); else hideDock.stop(); }
    }
    Connections {
        target: hotBottom
        function onContainsMouseChanged() { if (!hotBottom.containsMouse) hideDock.restart(); }
    }
}
