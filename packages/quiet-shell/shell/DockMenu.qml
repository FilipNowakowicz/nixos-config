import QtQuick
import QtQuick.Layouts

// The dock's right-click menu: this app's windows, then what you can do with it.
Item {
    id: root
    readonly property var app: Ui.dockMenu ? Ui.dockMenu.app : null
    width: 240
    height: body.implicitHeight + 12
    MouseArea { anchors.fill: parent }
    Glass { anchors.fill: parent; radius: 16 }

    component Row: Press {
        id: row
        property string title
        Layout.fillWidth: true
        implicitHeight: 30
        radius: 9
        name: title
        Label { x: 10; width: parent.width - 20; anchors.verticalCenter: parent.verticalCenter; text: row.title }
    }
    ColumnLayout {
        id: body
        x: 6
        y: 6
        width: parent.width - 12
        spacing: 0
        Repeater {
            model: root.app ? root.app.windows : []
            Row {
                required property var modelData
                title: modelData.title || root.app.name
                onClicked: { Ui.close(); Dockable.revealAfterClose(modelData); }
            }
        }
        Rectangle { Layout.fillWidth: true; Layout.margins: 4; Layout.leftMargin: 9; Layout.rightMargin: 9; implicitHeight: 1; color: Theme.hairline }
        Row {
            title: "New Window"
            onClicked: { Dockable.launch(root.app); Ui.close(); }
        }
        Row {
            title: root.app && root.app.windows.length > 1 ? "Close All" : "Close"
            onClicked: { Dockable.closeAll(root.app); Ui.close(); }
        }
    }
}
