import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the font panel. Clicking runs the same IPC route a keybinding
// would (omarchy-shell shell toggle …), matching the sibling nosignal.*
// widgets. Static icon, no polling while the panel is closed.
BarWidget {
  id: root
  moduleName: "nosignal.omafont"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰛖"
    tooltipText: "Fonts"
    foreground: Color.accent
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle nosignal.omafont")
    }
  }
}
