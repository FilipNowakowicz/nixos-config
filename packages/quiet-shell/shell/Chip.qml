import QtQuick

// A small choice: one of a set (a style), or a switch of its own (show a line).
// Lit while chosen, as a chosen option is elsewhere in the shell.
Press {
    id: root
    property string text
    implicitWidth: word.implicitWidth + 16
    implicitHeight: 22
    radius: 11
    name: text
    checkable: true
    rest: toggled ? Theme.on : Theme.fill
    hover: toggled ? Theme.on : Theme.fillHover
    Label {
        id: word
        anchors.centerIn: parent
        text: root.text
        font.pixelSize: 11
        color: root.toggled ? Theme.onText : Theme.text
    }
}
