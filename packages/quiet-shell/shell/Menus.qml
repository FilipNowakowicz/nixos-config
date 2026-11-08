import QtQuick
import QtQuick.Layouts

// Plain text menus, as macOS has for the Apple and battery menus.
Item {
    id: root
    property Item systemAnchor
    property Item batteryAnchor

    component MenuRow: Press {
        id: row
        property string title
        property string hint
        property bool checked: false
        Layout.fillWidth: true
        implicitHeight: 30
        radius: 9
        name: title
        Icon { visible: row.checked; x: 9; anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 13 }
        Label { x: 28; anchors.verticalCenter: parent.verticalCenter; text: row.title }
        Label { visible: row.hint !== ""; anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; text: row.hint; font.pixelSize: 10; font.weight: Font.Medium; color: Theme.faint }
    }

    // SUPER+Escape opens the system menu; a letter picks a row, as in the control centre.
    function pressLetter(letter) {
        const sessions = { s: "sleep", r: "restart", d: "shutdown", l: "lock", o: "logout" };
        if (Ui.panel !== "system" || !sessions[letter])
            return false;
        Ui.session(sessions[letter]);
        return true;
    }
    component Sep: Rectangle { Layout.fillWidth: true; Layout.margins: 4; Layout.leftMargin: 9; Layout.rightMargin: 9; implicitHeight: 1; color: Theme.hairline }

    Item {
        visible: Ui.panel === "system"
        x: 8
        y: 42
        width: 230
        height: systemBody.implicitHeight + 12
        MouseArea { anchors.fill: parent }
        Glass { anchors.fill: parent; radius: 16 }
        ColumnLayout {
            id: systemBody
            x: 6
            y: 6
            width: parent.width - 12
            spacing: 0
            MenuRow { title: "Sleep"; hint: "S"; onClicked: Ui.session("sleep") }
            MenuRow { title: "Restart"; hint: "R"; onClicked: Ui.session("restart") }
            MenuRow { title: "Shut Down"; hint: "D"; onClicked: Ui.session("shutdown") }
            Sep {}
            MenuRow { title: "Lock Screen"; hint: "L"; onClicked: Ui.session("lock") }
            MenuRow { title: "Log Out"; hint: "O"; onClicked: Ui.session("logout") }
        }
    }

    Item {
        visible: Ui.panel === "battery"
        anchors.right: parent.right
        anchors.rightMargin: 8
        y: 42
        width: 260
        height: batteryBody.implicitHeight + 12
        MouseArea { anchors.fill: parent }
        Glass { anchors.fill: parent; radius: 16 }
        ColumnLayout {
            id: batteryBody
            x: 6
            y: 6
            width: parent.width - 12
            spacing: 0
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                Layout.preferredHeight: 30
                Label { text: "Battery"; font.weight: Font.DemiBold; Layout.fillWidth: true }
                Label { text: Sys.battery ? Sys.battery.level + "%" + (Sys.battery.charging ? " · Charging" : "") : ""; color: Theme.dim }
            }
            Sep {}
            Label { Layout.leftMargin: 10; text: "Power mode"; font.pixelSize: 12; color: Theme.dim }
            MenuRow { title: "Low Power"; checked: Sys.profile === "power-saver"; onClicked: Sys.setProfile("power-saver") }
            MenuRow { title: "Balanced"; checked: Sys.profile === "balanced"; onClicked: Sys.setProfile("balanced") }
            MenuRow { title: "High Performance"; checked: Sys.profile === "performance"; onClicked: Sys.setProfile("performance") }
            FailRow { Layout.fillWidth: true; writeKey: "profile" }
        }
    }
}
