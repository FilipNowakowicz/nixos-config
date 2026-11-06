import QtQuick

NoticeCard {
    entry: Notify.banner
    anchors.right: parent.right
    anchors.rightMargin: entry ? 8 : -360
    y: 42
    opacity: entry ? 1 : 0
    Behavior on anchors.rightMargin { NumberAnimation { duration: Theme.motion; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: Theme.motion } }
}
