import QtQuick
import Quickshell.Wayland

// A window's picture, shrunk smoothly. Drawn straight into a small preview, the full
// buffer is sampled a few pixels apart and looks jagged and shimmers. Rendered into a
// mipmapped layer first, the GPU averages it down instead. The layer is capped so a
// large window costs a few MB, and previews only exist while something shows them.
ScreencopyView {
    id: root
    readonly property real shrink: sourceSize.width > 1280 ? 1280 / sourceSize.width : 1
    layer.enabled: hasContent
    layer.smooth: true
    layer.mipmap: true
    layer.textureSize: Qt.size(Math.max(1, Math.round(sourceSize.width * shrink)), Math.max(1, Math.round(sourceSize.height * shrink)))
}
