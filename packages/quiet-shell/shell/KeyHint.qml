import QtQuick

// The letter that presses a control. Only shown where the letters work.
Label {
    visible: text !== "" && Ui.panel === "controls"
    font.pixelSize: 10
    font.weight: Font.Medium
    color: Theme.faint
}
