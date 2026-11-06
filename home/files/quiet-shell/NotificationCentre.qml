import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    width: 340
    spacing: 8
    property bool compact: false

    readonly property date now: new Date()
    function days() {
        const y = now.getFullYear(), m = now.getMonth();
        const first = (new Date(y, m, 1).getDay() + 6) % 7;
        const count = new Date(y, m + 1, 0).getDate();
        const out = [];
        for (let i = 0; i < first; i++) out.push(0);
        for (let d = 1; d <= count; d++) out.push(d);
        return out;
    }

    Item {
        Layout.fillWidth: true
        implicitHeight: calendar.implicitHeight + 24
        Glass { anchors.fill: parent; radius: 22 }
        Column {
            id: calendar
            x: 14
            y: 12
            width: parent.width - 28
            spacing: 6
            Label { text: Qt.formatDate(root.now, "dddd d MMMM"); font.weight: Font.DemiBold; font.pixelSize: 15 }
            Grid {
                visible: !root.compact
                columns: 7
                width: parent.width
                Repeater {
                    model: ["M", "T", "W", "T", "F", "S", "S"]
                    Label { required property string modelData; width: parent.width / 7; height: 20; horizontalAlignment: Text.AlignHCenter; text: modelData; font.pixelSize: 11; color: Theme.dim }
                }
                Repeater {
                    model: root.days()
                    Item {
                        required property int modelData
                        readonly property bool today: modelData === root.now.getDate()
                        width: parent.width / 7
                        height: 24
                        Rectangle { anchors.centerIn: parent; visible: parent.today; width: 22; height: 22; radius: 11; color: Theme.on }
                        Label { anchors.centerIn: parent; visible: parent.modelData > 0; text: parent.modelData; font.pixelSize: 12; color: parent.today ? Theme.onText : Theme.text; font.weight: parent.today ? Font.DemiBold : Font.Normal }
                    }
                }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 8
        Layout.rightMargin: 4
        Layout.preferredHeight: 22
        Label { Layout.fillWidth: true; text: "Notifications"; font.pixelSize: 12; font.weight: Font.Medium }
        Press {
            visible: Notify.items.length > 0
            implicitWidth: 62
            implicitHeight: 22
            radius: 11
            name: "Clear all"
            onClicked: Notify.clear()
            Label { anchors.centerIn: parent; text: "Clear all"; font.pixelSize: 11 }
        }
    }
    Repeater {
        model: Notify.items.slice(0, root.compact ? 3 : 6)
        NoticeCard { required property var modelData; entry: modelData; Layout.fillWidth: true }
    }
    Item {
        visible: Notify.items.length === 0
        Layout.fillWidth: true
        implicitHeight: 44
        Glass { anchors.fill: parent; radius: 22 }
        Label { anchors.centerIn: parent; text: "Nothing new"; color: Theme.dim }
    }
}
