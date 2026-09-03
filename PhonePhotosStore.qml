pragma Singleton

import QtCore
import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Syncthing photo folder, and the one window that shows it.
//
// This is a singleton because a bar widget is instantiated once per monitor.
// With the window declared in the widget, a two-monitor setup gets two windows:
// clicking opens one, `shell summon` opens both, and closing one leaves the
// other behind. Keeping the model and the window here means every bar button
// is a view onto the same thing. Same reasoning as the downloads plugin.
//
// The folder is kept in sync with a phone by Syncthing. Photos arrive with the
// machine's own names, so every Text is PlainText - on the default AutoText,
// Qt decides for itself that a name looks like markup and renders it as rich
// text, and rich text really does fetch `<img src="http://...">`.
//
// The badge is "new since you last looked". The bar button carries a count of
// photos newer than a marker, and opening the window - or the folder - advances
// that marker. The marker lives in a small state file so it survives a shell
// restart: photos you have already seen are not "new" again tomorrow.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Singleton {
  id: root

  // Set from the widget's shell.json entry; see Panel.qml. Defaults hold until
  // the first widget configures them, so the window is never empty just because
  // a setting is missing.
  property url folderUrl:
    Util.fileUrl(Quickshell.env("HOME") + "/Pictures/Phone")

  readonly property string folderPath:
    String(root.folderUrl).replace(/^file:\/\//, "")

  // The header names the folder it is showing, shortened the way a shell prompt
  // would. Note this is not the window title: that stays "Phone Photos",
  // because the Hyprland rule that floats this window matches on it.
  readonly property string homePath:
    String(StandardPaths.writableLocation(StandardPaths.HomeLocation)).replace(/^file:\/\//, "")
  function plain(s) { return String(s || "").replace(/[<>]/g, "") }

  readonly property string displayPath: {
    var home = root.homePath
    var path = root.folderPath
    if (home !== "" && path.indexOf(home) === 0) return "~" + path.slice(home.length)
    return path
  }

  readonly property string iconPhotos: "\uF030"
  readonly property string iconFolder: "\uF07C"
  readonly property string iconImage: "\uF1C5"
  // Icon for a media row that has no thumbnail - videos, or an image the
  // decoder could not read. Kept distinct from the image glyph so a video is
  // recognisable at a glance.
  readonly property string iconVideo: "\uF03D"
  readonly property string iconCopy: "\uF0C5"
  // Icon for the row that asks Syncthing to rescan this folder now.
  readonly property string iconSync: "\uF021"

  property string fontFamily: Style.font.family

  // Rows currently shown, already filtered and capped.
  property var photos: []
  // How many are newer than the seen marker - what the bar badge shows.
  property int unseenCount: 0
  // Files left out because the list is capped.
  property int hiddenCount: 0
  // Files past the scan cap, counted from the model but never read.
  property int uncountedCount: 0
  // The oldest moment that counts as "already seen". Newer photos are new.
  // Null until the helper has answered once or the marker has been written.
  property double seenMarker: 0
  property bool markerLoaded: false
  // True until the marker has a value that came from disk or from a first
  // scan. While it is true, the badge stays quiet: the very first time the
  // widget runs there is no "last looked" to compare against, so the library is
  // all treated as seen rather than all at once as new.
  property bool firstRun: true
  // The row being dragged, so it can dim while the drag is in flight.
  property string draggingPath: ""
  // Whether the window is up. The widgets mirror this, they do not own it.
  property bool open: false
  // True while a manual rescan request to Syncthing is in flight, so the sync
  // button can show it is working (and ignore extra clicks).
  property bool syncing: false

  property int maxRows: 200

  // Entries a single rebuild is allowed to read out of the model, and the size
  // past which a folder is not watched at all. Same caps and reasoning as the
  // downloads plugin: cut the oldest tail, keep the newest end.
  readonly property int maxScan: 2000

  // Watching a folder is not free, and the price is set by the folder rather
  // than by the change: Qt re-reads the whole directory every time anything in
  // it moves. On a photo folder that is fine; on one nobody has ever cleaned
  // up it is not. The probe decides, and past the ceiling the model is detached
  // and the folder is polled instead - one scan per interval rather than one
  // per file. See the downloads plugin for the measured rationale.
  property bool polling: false
  property url scanFolder: ""

  function show() { root.showOn(null) }
  function hide() { root.open = false }
  function toggle() { root.open ? root.hide() : root.show() }

  // One window, many bar copies. The widget that opened it passes that bar's
  // screen so the list maps on the same output instead of Hyprland's last-used
  // monitor. Null keeps the current screen (IPC with no opener).
  function showOn(screen) {
    root.rescan()
    if (screen)
      win.screen = screen
    root.open = true
    root.markSeenThroughNewest()
  }

  // Opening the window is seeing. Advance the marker to the newest photo that
  // is in front of us right now, so the badge clears. Written so it survives a
  // restart.
  function markSeenThroughNewest() {
    var newest = 0
    for (var i = 0; i < root.photos.length; i++) {
      var m = root.photos[i].modified
      if (m > newest) newest = m
    }
    if (newest > 0 && newest > root.seenMarker) {
      root.seenMarker = newest
      root.unseenCount = 0
      root.writeMarker(newest)
    } else if (root.photos.length === 0) {
      root.seenMarker = 0
      root.unseenCount = 0
    }
  }

  function writeMarker(ts) {
    if (markerProc.running) return
    markerProc.command = [root.helper, "mark", String(ts)]
    markerProc.running = true
  }

  function suffixOf(name) {
    var m = /\.([A-Za-z0-9]+)$/.exec(String(name))
    return m ? m[1].toLowerCase() : ""
  }

  function isPhoto(name) {
    var s = root.suffixOf(name)
    return /^(png|jpe?g|gif|webp|bmp|heic|heif|tiff?|avif|svg|mp4|m4v|mov|mkv|webm|avi|3gp)$/.test(s)
  }

  function isVideo(name) {
    var s = root.suffixOf(name)
    return /^(mp4|m4v|mov|mkv|webm|avi|3gp)$/.test(s)
  }

  function formatAge(ms) {
    var secs = Math.max(0, Math.round((Date.now() - ms) / 1000))
    if (secs < 45) return "just now"
    var mins = Math.round(secs / 60)
    if (mins < 60) return mins + " min"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + " h"
    var days = Math.floor(hours / 24)
    if (days < 7) return days + " d"
    var weeks = Math.floor(days / 7)
    if (weeks < 5) return weeks + " w"
    return Math.floor(days / 30) + " mo"
  }

  function formatSize(bytes) {
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) return ""
    if (n < 1024) return n + " B"
    if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB"
    if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(n < 10 * 1024 * 1024 ? 1 : 0) + " MB"
    return (n / (1024 * 1024 * 1024)).toFixed(1) + " GB"
  }

  // Rebuild the visible list and recount what is unseen. The cost of one run is
  // bounded by maxScan rather than by the size of the folder.
  function rebuild() {
    var out = []
    var skipped = 0

    var count = folderModel.count
    var scan = Math.min(count, root.maxScan)

    for (var i = 0; i < scan; i++) {
      var name = String(folderModel.get(i, "fileName") || "")
      if (name === "" || name.charAt(0) === "." || !root.isPhoto(name)) continue

      var mod = folderModel.get(i, "fileModified")
      var ms = mod ? mod.getTime() : 0

      if (out.length >= root.maxRows) { skipped++; continue }

      out.push({
        name: name,
        url: String(folderModel.get(i, "fileUrl") || ""),
        path: String(folderModel.get(i, "filePath") || ""),
        size: Number(folderModel.get(i, "fileSize")) || 0,
        modified: ms
      })
    }

    // Time sorting comes back newest first, which is the order the window wants:
    // the photo you just shot is the one you came for.

    root.finalizeScan(out, skipped, count - scan)
  }

  // Whatever produced the rows - the folder model or the helper - lands here to
  // be counted and published. This is where the badge and the first-run marker
  // are decided, once, so both paths tell the same story.
  function finalizeScan(out, skipped, uncounted) {
    // First run, no marker written yet. The newest photo in front of us becomes
    // the "already seen" baseline, so the badge starts quiet: everything already
    // in the library is treated as seen rather than as a wall of "new". The
    // baseline is written now, and never again on this side. On an empty folder
    // that baseline is 0, which is exactly right: the first photo that lands
    // afterwards is newer than it and counts as new.
    if (root.firstRun) {
      var newest = 0
      for (var i = 0; i < out.length; i++) {
        var m = out[i].modified
        if (m > newest) newest = m
      }
      root.seenMarker = newest
      root.writeMarker(newest)
      root.firstRun = false
      root.photos = out
      root.hiddenCount = skipped
      root.uncountedCount = uncounted
      root.unseenCount = 0
      return
    }

    var unseen = 0
    for (var j = 0; j < out.length; j++) {
      if (out[j].modified > root.seenMarker) unseen++
    }
    root.photos = out
    root.hiddenCount = skipped
    root.uncountedCount = uncounted
    root.unseenCount = unseen
  }

  function tick() {
    if (root.polling) { root.readViaHelper(); return }
    if (String(root.scanFolder) === "" || folderModel.status !== FolderListModel.Ready) return

    root.rebuild()

    if (folderModel.count > root.maxScan) {
      root.polling = true
      root.scanFolder = ""
      root.readViaHelper()
    }
  }

  function rescan() {
    if (probeProc.running) return
    probeProc.command = [root.helper, "probe", root.folderPath]
    probeProc.running = true
  }

  property var folderProbe: null

  function applyProbe(text) {
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!data || data.ok !== true) return
    root.folderProbe = data

    if (data.over === true) {
      root.polling = true
      if (String(root.scanFolder) !== "") root.scanFolder = ""
      root.readViaHelper()
      return
    }

    root.polling = false
    if (String(root.scanFolder) === "") root.scanFolder = root.folderUrl
    else root.tick()
  }

  function readViaHelper() {
    if (listProc.running) return
    listProc.command = [root.helper, "list", root.folderPath]
    listProc.running = true
  }

  // The helper's answer, in the same shape rebuild() produces from the model,
  // so everything downstream is unaware of which path it came from. For the
  // URL, use the percent-encoded form the model would have built: a filename is
  // bytes and may include characters a URI has to encode.
  function fileUrl(path) {
    var parts = String(path || "").split("/")
    for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
    return "file://" + parts.join("/")
  }

  function applyPayload(text) {
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!data || data.ok !== true || !Array.isArray(data.files)) return

    var out = []
    var skipped = 0

    for (var i = 0; i < data.files.length; i++) {
      var f = data.files[i]
      var name = String(f.name || "")
      if (name === "" || name.charAt(0) === "." || !root.isPhoto(name)) continue

      var ms = Number(f.modified) || 0

      if (out.length >= root.maxRows) { skipped++; continue }

      out.push({
        name: name,
        url: root.fileUrl(f.path),
        path: String(f.path || ""),
        size: Number(f.size) || 0,
        modified: ms
      })
    }

    root.finalizeScan(out, skipped, Number(data.hidden) || 0)
  }

  function applyMarker(text) {
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    if (!data || data.ok !== true) return
    root.markerLoaded = true
    if (data.marker !== null && data.marker !== undefined) {
      root.seenMarker = Number(data.marker)
      root.firstRun = false
    } else {
      // No marker on disk: this is the first run (or the state file was
      // deleted). firstRun is left true; the first scan will establish the
      // marker at the newest photo and keep the badge quiet. The next genuinely
      // new photo triggers it.
      root.seenMarker = 0
    }
    root.tick()
  }

  function scheduleTick() { coalesce.restart() }

  function openFolder() {
    var target = root.folderPath
    if (target.length > 1 && target.charAt(0) === "/")
      Quickshell.execDetached(["xdg-open", target])
    // Opening the folder is seeing: advance the marker, same as opening the
    // window, so the badge clears even if you go straight to the file manager.
    root.markSeenThroughNewest()
  }

  // Trigger a Syncthing rescan of the watched folder. One request at a time:
  // ignore clicks while a scan is already running.
  function syncNow() {
    if (root.syncing) return
    root.syncing = true
    syncProc.command = [root.helper, "scan"]
    syncProc.running = true
  }

  readonly property string helper:
    Qt.resolvedUrl("bin/phone-photos").toString().replace(/^file:\/\//, "")

  // A new folder is a new size question. Detach the model first: the old
  // folder's answer says nothing about this one, and attaching before the probe
  // is exactly the unbounded read this is here to prevent. The old snapshot
  // stands until the new one lands.
  onFolderUrlChanged: {
    root.polling = false
    root.folderProbe = null
    root.scanFolder = ""
    root.rescan()
  }

  Component.onCompleted: {
    root.rescan()
    root.loadMarker()
  }

  function loadMarker() {
    if (markerProc.running) return
    markerProc.command = [root.helper, "getmark"]
    markerProc.running = true
  }

  Process {
    id: probeProc
    stdout: StdioCollector {
      onStreamFinished: root.applyProbe(text)
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
  }

  Process {
    id: markerProc
    stdout: StdioCollector {
      onStreamFinished: root.applyMarker(text)
    }
  }

  // A manual sync: ask Syncthing to rescan the folder now, then refresh the
  // list so whatever new photos just landed show up without waiting for the
  // hourly rescan or the widget's own poll.
  Process {
    id: syncProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.syncing = false
        root.rescan()
      }
    }
  }

  FolderListModel {
    id: folderModel
    folder: root.scanFolder
    showDirs: false
    showHidden: false
    showDotAndDotDot: false
    // Time sorting comes back newest first, which is the order the window wants:
    // the photo you just shot is the one you came for.
    sortField: FolderListModel.Time
    sortReversed: false
    onCountChanged: root.scheduleTick()
    onStatusChanged: if (status === FolderListModel.Ready) root.scheduleTick()
  }

  // Photos arrive whenever Syncthing delivers them, and the badge has to clear
  // once enough time passes that a "just arrived" moment is no longer current.
  // With the window closed this mostly drives the badge, and that can wait.
  // Fast enough to feel live, slow enough to stay invisible.
  Timer {
    interval: root.open ? 20000 : 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.rescan()
  }

  Timer {
    id: coalesce
    interval: 250
    repeat: false
    onTriggered: root.tick()
  }

  FloatingWindow {
    id: win

    visible: root.open
    title: "Phone Photos"
    color: Color.popups.background
    implicitWidth: Style.space(520)

    readonly property int rowStride: Style.space(38) + Style.space(2)
    readonly property int chromeHeight: Style.space(104)
    readonly property int listHeight: Math.min(Style.space(500),
      Math.max(Style.space(64), root.photos.length * rowStride))
    implicitHeight: chromeHeight + listHeight

    minimumSize: Qt.size(Style.space(360), Style.space(160))

    onVisibleChanged: if (!visible && root.open) root.open = false

    FocusScope {
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.hide()

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: root.iconPhotos
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
            renderType: Text.NativeRendering
            color: root.unseenCount > 0 ? Color.accent : Color.foreground
          }

          Text {
            Layout.fillWidth: true
            Layout.preferredWidth: 0
            text: root.displayPath
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            renderType: Text.NativeRendering
            color: Color.foreground
          }

          Button {
            Layout.alignment: Qt.AlignVCenter
            iconText: root.iconFolder
            tooltipText: root.plain("Open " + root.displayPath)
            foreground: Util.alpha(Color.foreground, 0.6)
            accent: Color.accent
            fontFamily: root.fontFamily
            iconSize: Style.font.iconSmall
            onClicked: root.openFolder()
          }

          Button {
            Layout.alignment: Qt.AlignVCenter
            iconText: root.iconSync
            tooltipText: root.plain("Sync now")
            foreground: Util.alpha(Color.foreground, 0.6)
            accent: Color.accent
            fontFamily: root.fontFamily
            iconSize: Style.font.iconSmall
            iconSpinning: root.syncing
            onClicked: root.syncNow()
          }
        }

        Rectangle {
          Layout.fillWidth: true
          height: Style.spacing.hairline
          color: Color.popups.border
        }

        ListView {
          id: list
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.minimumHeight: 0
          visible: root.photos.length > 0
          clip: true
          spacing: Style.space(2)
          model: root.photos
          boundsBehavior: Flickable.StopAtBounds

          delegate: PhotoRow {
            required property var modelData
            width: list.width
            store: root
            file: modelData || ({})
          }
        }

        Text {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.photos.length === 0
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.polling
            ? "Photos and videos are syncing..."
            : "No photos yet in " + root.displayPath + ".\n"
               + "Take a picture on your phone and it should appear here."
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
          color: Color.foreground
        }

        Rectangle {
          Layout.fillWidth: true
          height: Style.spacing.hairline
          color: Color.popups.border
        }

        Text {
          Layout.fillWidth: true
          visible: root.hiddenCount > 0 || root.uncountedCount > 0
          textFormat: Text.PlainText
          text: root.uncountedCount > 0
            ? "Newest " + root.photos.length + " of more than " + root.maxScan + " photos & videos"
            : "+ " + root.hiddenCount + " more not shown"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
          color: Util.alpha(Color.foreground, 0.6)
        }

        Text {
          Layout.fillWidth: true
          visible: root.photos.length > 0
          textFormat: Text.PlainText
          text: "Files can be dragged and dropped"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
          color: Util.alpha(Color.foreground, 0.6)
        }
      }
    }
  }
}
