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
    WlrLayershell.keyboardFocus: Ui.blocking ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

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
        Keys.onReturnPressed: event => { if (Ui.switcher) Ui.commitSwitcher(); else event.accepted = false; }
        Keys.onReleased: event => {
            if (Ui.switcher && (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta))
                Ui.commitSwitcher();
        }
        Keys.onTabPressed: event => { if (Ui.switcher) Ui.stepSwitcher(1); else event.accepted = false; }

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
            anchors.fill: parent
            active: Ui.overview && win.focused
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
            visible: (Ui.panel === "notifications" || opacity > 0) && win.focused
            x: parent.width - width - 8 + (Ui.panel === "notifications" ? 0 : 20)
            y: 42
            opacity: Ui.panel === "notifications" ? 1 : 0
            Behavior on x { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: Theme.motion } }
        }

        Menus { anchors.fill: parent; visible: win.focused }

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

        Screenshot {
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

        Dock {
            id: dock
            anchors.horizontalCenter: parent.horizontalCenter
            visible: win.focused && Dockable.apps.length > 0
            y: parent.height - (Ui.dockRevealed || Ui.overview ? height + 6 : -10)
            Behavior on y { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
        }
    }

    Connections {
        target: Ui
        function onRefocus() { root.forceActiveFocus(); }
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
