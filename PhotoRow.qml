import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// One photo in the synced folder, and the thing you actually drag.
//
// The drag is the point of this widget, so a note on how it is wired. It is the
// same arrangement as the downloads plugin's row: Drag.dragType Automatic makes
// this a real Wayland drag (wl_data_device.start_drag) rather than an in-scene
// one. text/uri-list is the format file managers, browsers and chat apps read;
// text/plain is there for fields that only take text. The URL is a local file -
// Syncthing has already put the photo on this machine - so dropping it anywhere
// hands over a real, present file with no rounding it up first.
//
// Drag and drag.target both live on this same row, deliberately. Splitting them
// over a separate handle makes the drag start and finish in the same instant.
// The row does get moved by the drag, but Drag.Automatic hands the pointer to
// the compositor immediately, so it never travels far enough to see.
Item {
  id: row

  // The PhonePhotosStore, for formatting helpers and shared drag state.
  property var store: null
  // { name, url, path, size, modified }
  property var file: ({})

  readonly property bool dragging: store !== null && !!file && store.draggingPath === file.path
  readonly property bool isPhoto: store !== null && !!file && store.isPhoto(file.name)
  readonly property bool isVideo: store !== null && !!file && store.isVideo(file.name)
  // A thumbnail is only possible for real image files; a video has nothing Qt
  // can decode into a picture, so it is skipped and the fallback glyph is used.
  readonly property bool isImage: store !== null && !!file && !row.isVideo && store.isPhoto(file.name)

  implicitHeight: Style.space(38)
  height: implicitHeight

  Drag.active: mouse.drag.active
  Drag.dragType: Drag.Automatic
  Drag.supportedActions: Qt.CopyAction
  Drag.mimeData: ({
    "text/uri-list": String(row.file.url || "") + "\r\n",
    "text/plain": String(row.file.url || "")
  })
  Drag.onDragStarted: if (row.store) row.store.draggingPath = String(row.file.path || "")
  Drag.onDragFinished: if (row.store) row.store.draggingPath = ""

  Rectangle {
    anchors.fill: parent
    radius: Style.space(4)
    color: row.dragging
      ? Util.alpha(Color.accent, 0.22)
      : (mouse.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent")
    border.width: row.dragging ? Style.spacing.hairline : 0
    border.color: Color.accent
  }

  RowLayout {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.right: copyBtn.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    // The thumbnail. Loaded asynchronously and cached, at 2x the drawn size so
    // it stays sharp on a scaled/retina output without decoding the full file.
    // PreserveAspectCrop fills the square; a crushed or tilted shot still reads
    // as a recognizable little box. A failed or non-image file falls back to a
    // plain image glyph.
    Item {
      Layout.alignment: Qt.AlignVCenter
      implicitWidth: Style.space(28)
      implicitHeight: Style.space(28)
      clip: true

      Image {
        id: thumb
        anchors.fill: parent
        visible: row.isImage
        source: row.isImage ? String(row.file.url || "") : ""
        asynchronous: true
        cache: true
        sourceSize: Qt.size(Style.space(56), Style.space(56))
        fillMode: Image.PreserveAspectCrop
      }

      Rectangle {
        anchors.fill: parent
        radius: Style.space(4)
        visible: !thumb.visible
        border.width: Style.spacing.hairline
        border.color: Util.alpha(Color.foreground, 0.15)
        color: "transparent"

        Text {
          anchors.centerIn: parent
          text: (row.store && row.isVideo && row.store.iconVideo)
            ? String(row.store.iconVideo)
            : ((row.store && row.store.iconImage) ? String(row.store.iconImage) : "")
          textFormat: Text.PlainText
          font.family: String((row.store && row.store.fontFamily) || Style.font.family || "")
          font.pixelSize: Style.font.iconSmall
          renderType: Text.NativeRendering
          color: Color.muted
        }
      }
    }

    Text {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      Layout.alignment: Qt.AlignVCenter
      text: row.file && row.file.name ? String(row.file.name) : ""
      textFormat: Text.PlainText
      elide: Text.ElideMiddle
      font.family: String((row.store && row.store.fontFamily) || Style.font.family || "")
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
      color: Color.foreground
    }

    Text {
      Layout.alignment: Qt.AlignVCenter
      text: (row.store && row.file)
        ? String(row.store.formatAge(row.file.modified) || "")
          + (row.file.size > 0 ? "  ·  " + String(row.store.formatSize(row.file.size) || "") : "")
        : ""
      textFormat: Text.PlainText
      font.family: String((row.store && row.store.fontFamily) || Style.font.family || "")
      font.pixelSize: Style.font.caption
      renderType: Text.NativeRendering
      color: Color.foreground
    }
  }

  MouseArea {
    id: mouse
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: copyBtn.left
    hoverEnabled: true
    cursorShape: mouse.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
    drag.target: row
    drag.threshold: Style.space(6)

    // Grab a picture of the row on press, so the drag carries something you can
    // recognise. Asynchronous, but press comes well before the drag threshold;
    // if it is not ready the drag simply has no image.
    onPressed: {
      row.grabToImage(function(result) {
        if (result) row.Drag.imageSource = result.url
      })
    }

    // A click opens the photo in the default viewer; a drag is press-and-move
    // and past the threshold, so a static click is a distinct gesture and can
    // never be mistaken for the start of a drag. Quickshell execDetached with
    // an argument array, never Util.execDetached: that takes a string and runs
    // it through `bash -lc`, and a filename is chosen by Samsung. The array
    // form execs directly, and the leading-slash check keeps a name that
    // starts with a dash from being read as an option.
    onClicked: {
      var target = String(row.file.path || "")
      if (target.length > 1 && target.charAt(0) === "/")
        Quickshell.execDetached(["xdg-open", target])
    }
  }

  // Copy the photo itself to the clipboard as text/uri-list, so you can paste
  // it into a chat, email or file manager the way the drag hands it over.
  // Real CR + LF bytes round-trip through Util.shellQuote's single quotes --
  // bash passes them verbatim -- and the uri-list spec wants each URI ended
  // with CRLF. Declared after the drag area, so it stacks on top and its own
  // clicks work without ever being mistaken for a drag; the drag area stops
  // before it to leave this corner alone.
  PanelActionButton {
    id: copyBtn
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    iconText: (row.store && row.store.iconCopy) ? String(row.store.iconCopy) : ""
    tooltipText: "Copy photo"
    foreground: Util.alpha(Color.foreground, 0.6)
    fontSize: Style.font.iconSmall
    onClicked: {
      if (!row.file || !row.file.url) return
      Quickshell.execDetached(["bash", "-c",
        "printf %s " + Util.shellQuote(String(row.file.url) + "\r\n")
          + " | wl-copy --type text/uri-list"])
    }
  }
}
