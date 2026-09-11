import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Font manager panel. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.omafont
//   omarchy-shell shell summon nosignal.omafont '{"install":"/path/to/x.ttf"}'
//
// The second form is what the .desktop mime handler uses, so double-clicking a
// font file in a file manager opens this panel with that file staged: loaded
// from disk, previewed, and one click from being installed. Dropping a file on
// the panel does the same thing.
//
// Installing is a copy into ~/.local/share/fonts/<Family>/ plus fc-cache --
// no root, no polkit. Removal is refused for anything outside that directory,
// so pacman-owned system fonts can be previewed but never deleted from here.
//
// Centred modal (plugin-manager / system-monitor idiom): a card over a scrim,
// theme tokens only. Esc/q or click-outside closes, / focuses the filter,
// r rescans.
Item {
  id: root

  property bool opened: false

  readonly property string selfId: "nosignal.omafont"

  // Injected by the shell host after the Loader resolves. Keeps the host's
  // open-flag honest on close(), and self-restores a visibly-open instance if
  // the host's panel Instantiator rebuild destroys it. Same pattern as the
  // sibling panel-kind plugins -- REQUIRED so this survives plugin-manager
  // toggles.
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // ---- Theme -------------------------------------------------------------
  // Shares the [menu] surface tokens so themes that style the menu style this
  // panel too -- same approach as the sibling panels.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.lg
  readonly property int railWidth: Style.space(230)
  readonly property int rowH: Style.font.body + Style.spacing.sm
  readonly property int headerH: Style.font.title + Style.spacing.md

  // ---- Model -------------------------------------------------------------
  // families: [{ name, styles: [..], files: [..], user: bool, mono: bool }]
  // Built from one fc-list pass, deduped by family, sorted case-insensitively.
  property var families: []
  property string filter: ""

  // Language-coverage fonts are hidden by default. On a stock Arch/Omarchy box
  // the Noto packages contribute ~300 of ~346 families -- every writing system
  // on earth, each in several widths -- which buries the couple of dozen fonts
  // anyone actually picks. They are infrastructure, like a codec: the browser
  // and terminal need them to render Arabic, CJK, Hebrew and emoji, so they
  // must stay installed; they just should not dominate a chooser.
  //
  // The base Noto faces are ordinary, choosable text fonts, so they stay
  // visible -- it is the per-script variants that get folded away.
  property bool hideCoverage: true
  readonly property var coverageKeep: [
    "Noto Sans", "Noto Serif", "Noto Sans Mono", "Noto Sans Display",
    "Noto Serif Display", "Noto Color Emoji", "Noto Emoji"
  ]

  function isCoverage(name) {
    if (name.indexOf("Noto ") !== 0) return false
    return root.coverageKeep.indexOf(name) < 0
  }

  readonly property int coverageCount: {
    var n = 0
    for (var i = 0; i < root.families.length; i++)
      if (root.isCoverage(root.families[i].name)) n++
    return n
  }
  property string selectedName: ""
  property bool scanning: false
  property string status: ""
  property bool hasPicker: false

  // A font file that is NOT installed yet: staged from a drop or from the
  // mime-handler payload. Previewed through stagedLoader, which reads the file
  // directly, so it renders without touching the font directories.
  property string stagedPath: ""

  readonly property string stagedName: {
    if (!root.stagedPath) return ""
    var p = root.stagedPath.split("/")
    return p[p.length - 1]
  }

  // True once the staged file's family is already present on disk. Turns the
  // Install button into a labelled no-op rather than silently overwriting.
  readonly property bool stagedInstalled: {
    if (!stagedLoader.name) return false
    for (var i = 0; i < root.families.length; i++)
      if (root.families[i].name === stagedLoader.name) return true
    return false
  }

  readonly property var selected: {
    for (var i = 0; i < root.families.length; i++)
      if (root.families[i].name === root.selectedName) return root.families[i]
    return null
  }

  // Rows for the rail: section headers interleaved with families, user fonts
  // first because they are the ones you can actually act on.
  readonly property var rows: {
    var f = root.filter.toLowerCase()
    var mine = [], sys = []
    for (var i = 0; i < root.families.length; i++) {
      var fam = root.families[i]
      if (f && fam.name.toLowerCase().indexOf(f) < 0) continue
      // Typing a filter searches everything. Someone who types "tamil" wants
      // the Tamil fonts, and silently withholding them would read as a bug.
      if (!f && root.hideCoverage && root.isCoverage(fam.name)) continue
      if (fam.user) mine.push(fam); else sys.push(fam)
    }
    var out = []
    if (mine.length) {
      out.push({ header: true, label: "Yours", count: mine.length })
      for (var j = 0; j < mine.length; j++) out.push({ header: false, fam: mine[j] })
    }
    if (sys.length) {
      out.push({ header: true, label: "System", count: sys.length })
      for (var k = 0; k < sys.length; k++) out.push({ header: false, fam: sys[k] })
    }
    return out
  }

  // The file the preview renders from. Staged file wins; otherwise the
  // selected family's Regular-ish face. Loading the file directly rather than
  // trusting Qt's family lookup is what makes a just-installed font preview
  // immediately -- Qt only snapshots installed families at process start.
  readonly property string previewFile: {
    if (root.stagedPath) return root.stagedPath
    var s = root.selected
    if (!s || !s.files.length) return ""
    for (var i = 0; i < s.files.length; i++)
      if (/-?regular\./i.test(s.files[i]) || /[-_]R\./.test(s.files[i])) return s.files[i]
    return s.files[0]
  }

  // Resolved family name to render with: whatever the FontLoader actually
  // produced, falling back to the fc-list name if the file would not load.
  readonly property string previewFamily: {
    if (stagedLoader.name) return stagedLoader.name
    return root.selected ? root.selected.name : ""
  }

  FontLoader {
    id: stagedLoader
    source: root.previewFile ? "file://" + root.previewFile : ""
  }

  // ---- Scan --------------------------------------------------------------
  // One fc-list pass gives family, style, path and spacing. spacing 100 is
  // fontconfig's mono flag, which is what gates "Set as terminal font".
  Process {
    id: scanner
    command: ["fc-list", "--format", "%{family[0]}\t%{style[0]}\t%{file}\t%{spacing}\n"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.parseFcList(this.text)
        root.scanning = false
      }
    }
    onExited: function(code) {
      root.scanning = false
      if (code !== 0 && !root.families.length)
        root.status = "fc-list failed -- is fontconfig installed?"
    }
  }

  function parseFcList(text) {
    var lines = text.split("\n")
    // Bounded: a pathological font tree should not stall the shell. ~2600
    // faces is typical; 40k is far past any real install.
    var cap = Math.min(lines.length, 40000)
    var map = ({})
    var home = Quickshell.env("HOME") || ""
    var userRoot = home + "/.local/share/fonts"
    for (var i = 0; i < cap; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 3) continue
      var name = parts[0].trim()
      var style = parts[1].trim()
      var file = parts[2].trim()
      var spacing = parts.length > 3 ? parts[3].trim() : ""
      if (!name || !file) continue
      var e = map[name]
      if (!e) {
        e = { name: name, styles: [], files: [], user: false, mono: false }
        map[name] = e
      }
      if (style && e.styles.indexOf(style) < 0) e.styles.push(style)
      if (e.files.indexOf(file) < 0) e.files.push(file)
      if (userRoot && file.indexOf(userRoot + "/") === 0) e.user = true
      if (spacing === "100") e.mono = true
    }
    var out = []
    for (var k in map) out.push(map[k])
    out.sort(function(a, b) {
      var an = a.name.toLowerCase(), bn = b.name.toLowerCase()
      return an < bn ? -1 : (an > bn ? 1 : 0)
    })
    root.families = out
    if (root.selectedName) {
      var still = false
      for (var j = 0; j < out.length; j++)
        if (out[j].name === root.selectedName) { still = true; break }
      if (!still) root.selectedName = ""
    }
  }

  function refresh() {
    if (root.scanning) return
    root.scanning = true
    scanner.running = true
  }

  // ---- Install -----------------------------------------------------------
  // $1 source file, $2 destination subdirectory (already sanitised in QML).
  // cp -f rather than -n: re-installing a font you already have should replace
  // it, which is what every "install" button anywhere does.
  readonly property string installScript: [
    'set -eu',
    'src="$1"; sub="$2"',
    'case "$src" in',
    '  *.ttf|*.TTF|*.otf|*.OTF|*.ttc|*.TTC|*.pfb|*.PFB) ;;',
    '  *) echo "unsupported file type" >&2; exit 2 ;;',
    'esac',
    '[ -f "$src" ] || { echo "no such file" >&2; exit 2; }',
    'dest="$HOME/.local/share/fonts/$sub"',
    'mkdir -p -- "$dest"',
    'cp -f -- "$src" "$dest/"',
    'fc-cache -f -- "$dest" >/dev/null 2>&1 || fc-cache -f >/dev/null 2>&1 || true'
  ].join("\n")

  Process {
    id: installer
    stderr: StdioCollector {}
    onExited: function(code) {
      if (code === 0) {
        root.status = "Installed " + root.pendingLabel + " -- restart an app to use it"
        root.stagedPath = ""
        root.pendingSelect = root.pendingFamily
        root.refresh()
      } else {
        var msg = installer.stderr && installer.stderr.text ? installer.stderr.text.trim() : ""
        root.status = "Install failed" + (msg ? ": " + msg : "")
      }
    }
  }

  property string pendingLabel: ""
  property string pendingFamily: ""
  property string pendingSelect: ""

  onFamiliesChanged: {
    if (root.pendingSelect) {
      for (var i = 0; i < root.families.length; i++) {
        if (root.families[i].name === root.pendingSelect) {
          root.selectedName = root.pendingSelect
          break
        }
      }
      root.pendingSelect = ""
    }
  }

  // fontconfig family names are free text; the directory name is not. Strip it
  // to a safe slug so nothing in a font's metadata can steer the copy target.
  function slug(name) {
    var s = String(name).replace(/[^A-Za-z0-9._ -]/g, "").replace(/\s+/g, "-").replace(/^[-.]+/, "")
    return s.length ? s.slice(0, 64) : "Custom"
  }

  function installStaged() {
    if (!root.stagedPath) return
    var fam = stagedLoader.name || root.stagedName.replace(/\.[^.]+$/, "")
    root.pendingLabel = fam
    root.pendingFamily = fam
    root.status = "Installing " + fam + "..."
    installer.command = ["sh", "-c", root.installScript, "omafont-install",
                         root.stagedPath, root.slug(fam)]
    installer.running = true
  }

  // ---- Remove ------------------------------------------------------------
  // Every path is re-checked against the user font root inside the script, so
  // a bad selection in QML still cannot delete anything outside it. Empty
  // directories are pruned afterwards so uninstalling a family does not leave
  // its folder behind.
  readonly property string removeScript: [
    'set -eu',
    'root="$HOME/.local/share/fonts"',
    '[ -d "$root" ] || exit 0',
    'for f in "$@"; do',
    '  case "$f" in "$root"/*) ;; *) echo "refused: outside user font directory" >&2; exit 2 ;; esac',
    '  case "$f" in *..*) echo "refused: bad path" >&2; exit 2 ;; esac',
    '  [ -f "$f" ] || continue',
    '  rm -f -- "$f"',
    'done',
    'find "$root" -mindepth 1 -type d -empty -delete >/dev/null 2>&1 || true',
    'fc-cache -f >/dev/null 2>&1 || true'
  ].join("\n")

  Process {
    id: remover
    stderr: StdioCollector {}
    onExited: function(code) {
      if (code === 0) {
        root.status = "Removed " + root.pendingLabel
        root.selectedName = ""
        root.refresh()
      } else {
        var msg = remover.stderr && remover.stderr.text ? remover.stderr.text.trim() : ""
        root.status = "Remove failed" + (msg ? ": " + msg : "")
      }
    }
  }

  function removeSelected() {
    var s = root.selected
    if (!s || !s.user) return
    var home = Quickshell.env("HOME") || ""
    var userRoot = home + "/.local/share/fonts"
    var args = ["sh", "-c", root.removeScript, "omafont-remove"]
    for (var i = 0; i < s.files.length; i++)
      if (s.files[i].indexOf(userRoot + "/") === 0) args.push(s.files[i])
    if (args.length <= 4) return
    root.pendingLabel = s.name
    root.status = "Removing " + s.name + "..."
    remover.command = args
    remover.running = true
  }

  // ---- Set as terminal font ----------------------------------------------
  // Delegates to the stock omarchy-font-set, which owns the terminal configs
  // and the fontconfig monospace alias. Nothing here duplicates that logic.
  Process {
    id: monoSetter
    onExited: function(code) {
      root.status = code === 0
        ? "Terminal font set to " + root.pendingLabel
        : "omarchy-font-set failed"
    }
  }

  function setAsMono() {
    var s = root.selected
    if (!s || !s.mono) return
    root.pendingLabel = s.name
    monoSetter.command = ["omarchy-font-set", s.name]
    monoSetter.running = true
  }

  // ---- Optional file picker ----------------------------------------------
  // zenity is not a dependency: the button only appears if it is present, and
  // drag-and-drop plus the mime handler cover the same ground without it.
  Process {
    id: pickerProbe
    command: ["sh", "-c", "command -v zenity >/dev/null 2>&1"]
    onExited: function(code) { root.hasPicker = (code === 0) }
  }

  Process {
    id: picker
    command: ["zenity", "--file-selection", "--title=Choose a font file",
              "--file-filter=Fonts | *.ttf *.otf *.ttc *.TTF *.OTF *.TTC"]
    stdout: StdioCollector {
      onStreamFinished: {
        var p = this.text.trim()
        if (p) root.stage(p)
      }
    }
  }

  // ---- Staging -----------------------------------------------------------
  function stage(path) {
    if (!path) return
    var p = String(path)
    if (p.indexOf("file://") === 0) p = decodeURIComponent(p.substring(7))
    if (!/\.(ttf|otf|ttc|pfb)$/i.test(p)) {
      root.status = "Not a font file: " + p.split("/").pop()
      return
    }
    root.selectedName = ""
    root.stagedPath = p
    root.status = ""
  }

  function open(payloadJson) {
    root.opened = true
    root.ensureSelfReference()
    root.status = ""
    root.filter = ""
    pickerProbe.running = true
    root.refresh()
    // Focus the filter immediately: in a chooser this long, typing is the
    // primary way in, and making people click the box first is friction for
    // no gain. The shortcuts that would otherwise be swallowed (Esc, Enter)
    // are handled on the field itself.
    filterField.forceActiveFocus()
    try {
      var payload = JSON.parse(payloadJson || "{}")
      if (payload && payload.install) root.stage(payload.install)
    } catch (e) {
      // A malformed payload must never keep the panel from opening.
    }
  }

  // The host's hide() calls straight back into this close(), so the early
  // return is load-bearing, not defensive tidiness: without it the two recurse
  // until the JS stack blows ("Maximum call stack size exceeded") and the panel
  // never closes. Clearing `opened` first is what breaks the cycle on re-entry.
  function close() {
    if (!root.opened) return
    root.opened = false
    root.stagedPath = ""
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // ---- Self-reference ----------------------------------------------------
  // A plugin declaring bar-widget PLUS panel needs its own plugins[] entry or
  // the IPC shortcut dies with the bar icon. Claim one on first open --
  // idempotent, written through a temp file, inert once an entry exists.
  // Harness: sh -c <script> plugin-selfref <id> -- $0 is the label, $1 the id.
  property bool selfRefEnsured: false
  readonly property string ensureSelfRefScript: [
    'id="$1"',
    'f="$HOME/.config/omarchy/shell.json"',
    '[ -f "$f" ] || exit 0',
    'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0',
    'tmp="$f.selfref.$$"',
    'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {',
    '  rm -f "$tmp"; exit 1;',
    '}',
    '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }',
    'mv "$tmp" "$f"'
  ].join("\n")

  function ensureSelfReference() {
    if (root.selfRefEnsured) return
    root.selfRefEnsured = true
    Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript, "plugin-selfref", root.selfId])
  }

  // ---- UI ----------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omafont"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(880), panel.width - Style.gapsOut * 2)
      height: Math.max(0, Math.min(panel.height * 0.8, panel.height - Style.gapsOut * 2))
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      MouseArea { anchors.fill: parent; onClicked: {} }

      // Whole-card drop target: dropping a font file anywhere on the panel
      // stages it, which is the gesture people try first.
      DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: function(drop) {
          if (drop.hasUrls && drop.urls.length) {
            root.stage(drop.urls[0])
            drop.accept()
          }
        }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Q && !filterField.activeFocus) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Slash && !filterField.activeFocus) {
            filterField.forceActiveFocus()
            event.accepted = true
          } else if ((event.key === Qt.Key_R || event.key === Qt.Key_F5) && !filterField.activeFocus) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            // Enter installs a staged font. The staged state is the one moment
            // the panel has an obvious default action, and arriving here from a
            // double-click in the file manager means the hands are not on the
            // mouse anyway.
            if (root.stagedPath) {
              root.installStaged()
              event.accepted = true
            }
          }
        }
      }

      // BorderSurface.padding only publishes contentInset hints -- it does not
      // inset its children -- so a bare anchors.fill puts content hard against
      // the border. Apply the insets by hand, as the sibling panels do.
      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: root.contentSpacing

        // Header
        Item {
          width: parent.width
          height: root.headerH

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Fonts"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(90)
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
            text: {
              if (root.status !== "") return root.status
              if (root.scanning) return "Scanning..."
              if (root.hideCoverage && root.filter === "" && root.coverageCount > 0)
                return (root.families.length - root.coverageCount) + " of "
                       + root.families.length + " families"
              return root.families.length + " families"
            }
            color: root.status !== "" ? root.accent : root.foreground
            opacity: root.status !== "" ? 1.0 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          width: parent.width
          height: parent.height - root.headerH - root.contentSpacing * 2 - actions.height
          spacing: root.contentSpacing

          // ---- Left rail: filter + grouped family list ----
          Column {
            width: root.railWidth
            height: parent.height
            spacing: Style.spacing.sm

            TextField {
              id: filterField
              width: parent.width
              placeholderText: "Filter..."
              foreground: root.foreground
              accent: root.accent
              onTextChanged: root.filter = text
              Keys.onEscapePressed: {
                if (text.length) { text = "" } else { root.close() }
              }
              // The field has focus from the moment the panel opens, so it
              // owns Enter too -- otherwise Enter-to-install would only work
              // after clicking away from the filter.
              Keys.onReturnPressed: function(event) {
                if (root.stagedPath) {
                  root.installStaged()
                  event.accepted = true
                }
              }
            }

            // Coverage toggle. Doubles as the explanation for why the list is
            // short -- a silently filtered chooser is worse than a long one.
            Item {
              id: coverageBar
              width: parent.width
              height: root.coverageCount > 0 ? coverageLabel.implicitHeight : 0
              visible: root.coverageCount > 0

              Text {
                id: coverageLabel
                anchors.left: parent.left
                anchors.right: parent.right
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.filter !== ""
                      ? "searching all fonts"
                      : (root.hideCoverage
                         ? root.coverageCount + " language fonts hidden · show"
                         : "showing all · hide language fonts")
                color: root.filter !== "" ? root.foreground : root.accent
                opacity: root.filter !== "" ? 0.4 : 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                enabled: root.filter === ""
                cursorShape: Qt.PointingHandCursor
                onClicked: root.hideCoverage = !root.hideCoverage
              }
            }

            ListView {
              id: list
              width: parent.width
              height: parent.height - filterField.height - coverageBar.height
                      - Style.spacing.sm * (coverageBar.visible ? 2 : 1)
              clip: true
              model: root.rows
              spacing: 0
              boundsBehavior: Flickable.StopAtBounds

              delegate: Item {
                id: rowItem
                required property var modelData
                readonly property bool isHeader: modelData.header === true
                readonly property var fam: rowItem.isHeader ? null : modelData.fam

                width: list.width
                height: rowItem.isHeader ? root.rowH + Style.spacing.sm : root.rowH

                // Section header
                Text {
                  visible: rowItem.isHeader
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.spacing.xxs
                  textFormat: Text.PlainText
                  text: rowItem.isHeader
                        ? rowItem.modelData.label + " (" + rowItem.modelData.count + ")"
                        : ""
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                // Family row
                Rectangle {
                  visible: !rowItem.isHeader
                  anchors.fill: parent
                  radius: Math.max(2, Style.space(4))
                  color: {
                    if (rowItem.isHeader) return "transparent"
                    if (rowItem.fam.name === root.selectedName)
                      return Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                    if (rowMouse.containsMouse)
                      return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                    return "transparent"
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.sm
                    anchors.right: monoTag.left
                    anchors.rightMargin: Style.spacing.xs
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: rowItem.isHeader ? "" : rowItem.fam.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  // Monospace marker -- the only families "Set as terminal
                  // font" will accept, so it is worth showing in the list.
                  Text {
                    id: monoTag
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !rowItem.isHeader && rowItem.fam.mono
                    text: "M"
                    color: root.accent
                    opacity: 0.7
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                      if (rowItem.isHeader) return
                      root.stagedPath = ""
                      root.status = ""
                      root.selectedName = rowItem.fam.name
                    }
                  }
                }
              }
            }
          }

          // ---- Right: preview ----
          Item {
            width: parent.width - root.railWidth - root.contentSpacing
            height: parent.height

            // Empty state
            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(40)
              spacing: Style.spacing.sm
              visible: !root.selected && !root.stagedPath

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Pick a font to preview it"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: "Drop a .ttf or .otf here -- or double-click one in your file manager -- to preview it before installing."
                color: root.foreground
                opacity: 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Flickable {
              anchors.fill: parent
              visible: root.selected || root.stagedPath
              contentHeight: preview.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: preview
                width: parent.width
                spacing: Style.spacing.md

                // Name + provenance
                Column {
                  width: parent.width
                  spacing: Style.spacing.xxs

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.previewFamily
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: {
                      if (root.stagedPath)
                        return "Not installed -- " + root.stagedName
                               + (root.stagedInstalled ? " (family already installed)" : "")
                      var s = root.selected
                      if (!s) return ""
                      return (s.user ? "Yours" : "System")
                             + " -- " + s.styles.length + " style" + (s.styles.length === 1 ? "" : "s")
                             + (s.mono ? " -- monospace" : "")
                    }
                    color: root.stagedPath ? root.accent : root.foreground
                    opacity: root.stagedPath ? 1.0 : 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Specimen. Rendered from the loaded file, so a font installed
                // a second ago previews correctly even though Qt's family list
                // was snapshotted at shell start.
                Repeater {
                  model: [Style.space(34), Style.space(24), Style.space(17), Style.space(13)]

                  Text {
                    required property int modelData
                    width: preview.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: "The quick brown fox jumps over the lazy dog"
                    color: root.foreground
                    font.family: root.previewFamily
                    font.pixelSize: modelData
                  }
                }

                Rectangle {
                  width: parent.width
                  height: 1
                  color: root.foreground
                  opacity: 0.15
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WrapAnywhere
                  textFormat: Text.PlainText
                  text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789  &@#$%*()[]{}/\\ <>?!.,;:'\"-+="
                  color: root.foreground
                  opacity: 0.85
                  font.family: root.previewFamily
                  font.pixelSize: Style.space(16)
                  lineHeight: 1.35
                }

                // Styles in the family
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  visible: !root.stagedPath && root.selected && root.selected.styles.length > 0
                  text: root.selected ? root.selected.styles.join("  ·  ") : ""
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // ---- Actions ----
        Item {
          id: actions
          width: parent.width
          height: Style.space(30)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Button {
              text: "Install"
              bordered: true
              visible: root.stagedPath !== ""
              foreground: root.accent
              fontFamily: root.fontFamily
              onClicked: root.installStaged()
            }

            Button {
              text: "Cancel"
              bordered: true
              visible: root.stagedPath !== ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: { root.stagedPath = ""; root.status = "" }
            }

            Button {
              text: "Install from file..."
              bordered: true
              visible: root.stagedPath === "" && root.hasPicker
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: picker.running = true
            }

            Button {
              text: "Set as terminal font"
              bordered: true
              visible: root.stagedPath === "" && root.selected !== null && root.selected.mono
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.setAsMono()
            }
          }

          Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Remove"
            bordered: true
            visible: root.stagedPath === "" && root.selected !== null && root.selected.user
            foreground: root.urgent
            fontFamily: root.fontFamily
            onClicked: root.removeSelected()
          }
        }
      }
    }
  }
}
