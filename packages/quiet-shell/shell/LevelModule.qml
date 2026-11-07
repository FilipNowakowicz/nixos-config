import QtQuick
import QtQuick.Layouts

Item {
    id: root
    property string icon
    property string endIcon
    property string sliderName
    property int level
    property string detail
    property bool mutable: false
    signal moved(int value)
    signal mute

    implicitHeight: 42
    Glass { anchors.fill: parent; radius: 21 }
    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 11
        anchors.rightMargin: 11
        spacing: 7
        Press {
            implicitWidth: 22
            implicitHeight: 22
            radius: 11
            enabled: root.mutable
            name: root.mutable ? "Mute " + root.sliderName.toLowerCase() : ""
            onClicked: root.mute()
            Icon { anchors.centerIn: parent; name: root.icon; size: 14; color: Theme.dim }
        }
        ThinSlider {
            Layout.fillWidth: true
            name: root.sliderName
            level: root.level
            onChanged: value => root.moved(value)
        }
        Press {
            visible: root.detail !== ""
            implicitWidth: 22
            implicitHeight: 22
            radius: 11
            rest: Theme.fill
            name: "Choose " + root.sliderName.toLowerCase() + " device"
            onClicked: Ui.detail = root.detail
            Icon { anchors.centerIn: parent; name: "chevron-right"; size: 12 }
        }
        Icon { visible: root.endIcon !== ""; name: root.endIcon; size: 14; color: Theme.dim }
    }
}
