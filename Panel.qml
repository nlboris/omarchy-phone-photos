import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Phone Photos: what recently arrived on this machine from your phone, one
// click from the bar.
//
// The button carries a badge with the number of photos that are newer than the
// last time you looked, so a fresh sync is visible without opening anything.
// Clicking opens a window whose rows are drag handles, so a photo goes straight
// into the upload field or chat window that needs it.
//
// Everything that has state - the folder, the list, the seen marker, the window
// - lives in PhonePhotosStore, a singleton. A bar widget is instantiated once
// per monitor, so a window declared here would exist twice on a two-monitor
// setup. This file is the view: a button, a badge, and a way to reach the store.
Panel {
  id: root

  moduleName: "rob.phone-photos"
  ipcTarget: "rob.phone-photos"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int unseenCount: PhonePhotosStore.unseenCount
  readonly property bool hasUnseen: unseenCount > 0

  // Width of the badge and of the whole icon+badge row. Computed here rather
  // than inside iconComponent: that Component has its own scope, and ids
  // declared in it are invisible out here.
  readonly property int badgeWidth: unseenCount > 0
    ? Math.max(Style.space(12), String(unseenCount).length * Style.space(6) + Style.space(8))
    : 0
  readonly property int barContentWidth:
    Style.bar.iconFont + badgeWidth + (badgeWidth > 0 ? Style.space(5) : 0)

  readonly property int barSlot: barContentWidth + Style.space(10)
  readonly property real openPanelIndicatorWidth: barContentWidth
  readonly property real openPanelIndicatorHeight: barContentWidth
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // Settings live per bar entry in shell.json; the store is shared. Applied on
  // settingsChanged as well as on completion, because the host assigns
  // `settings` after constructing the widget.
  function applySettings() {
    var folder = String(root.setting("folder", ""))
    if (folder !== "") PhonePhotosStore.folderUrl = Util.fileUrl(folder)
    var rows = Number(root.setting("maxRows", 0))
    if (isFinite(rows) && rows >= 1) PhonePhotosStore.maxRows = Math.round(rows)
    PhonePhotosStore.fontFamily = root.fontFamily
  }

  onSettingsChanged: root.applySettings()
  Component.onCompleted: root.applySettings()

  // The bar button and the window mirror each other, in both directions:
  // `opened` follows a summon over IPC, and the store follows a click or the
  // window's own close button. Both sides check before assigning, so the two
  // handlers cannot bounce a change back and forth.
  function barScreen() {
    var window = root.QsWindow ? root.QsWindow.window : null
    return window ? window.screen : null
  }

  onOpenedChanged: {
    if (root.opened) {
      if (!PhonePhotosStore.open)
        PhonePhotosStore.showOn(root.barScreen())
    } else if (PhonePhotosStore.open) {
      PhonePhotosStore.hide()
    }
  }

  Connections {
    target: PhonePhotosStore
    function onOpenChanged() {
      if (PhonePhotosStore.open && !root.opened) root.open()
      else if (!PhonePhotosStore.open && root.opened) root.close()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    // The icon component is loaded into a square canvas of opticalSize, meant
    // for a single glyph. Widen it too, or the icon falls outside it and only
    // the badge survives.
    opticalSize: root.barContentWidth
    tooltipText: ""

    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: PhonePhotosStore.iconPhotos
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: (root.opened || root.hasUnseen) ? root.accent : root.foreground
          }

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.unseenCount > 0
            height: Style.space(12)
            width: root.badgeWidth
            radius: height / 2
            color: root.accent

            Text {
              anchors.centerIn: parent
              text: root.unseenCount
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
              color: Color.background
            }
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) PhonePhotosStore.openFolder()
      else root.toggle()
    }
  }
}
