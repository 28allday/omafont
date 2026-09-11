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
  property int contentSpacing: Style.spacing.xl
  readonly property int railWidth: Style.space(262)
  readonly property int rowH: Style.space(30)
  readonly property int headerH: Style.font.heading + Style.spacing.lg

  // Specimen sizes, largest first. Labelled in a left gutter so the pane reads
  // as a type specimen rather than four unexplained repetitions of a sentence.
  readonly property var specimenSizes: [56, 34, 24, 17, 12]

  readonly property string defaultSample: "The quick brown fox jumps over the lazy dog"
  property string sample: root.defaultSample

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

  // Fonts that are NOT installed yet: staged from a drop, the file picker, or
  // the mime-handler payload. A stage can be a single file, a folder, or a zip
  // -- a downloaded family is almost never one file, so installing one face at
  // a time would be the wrong unit of work.
  //
  // stagedFaces is what fc-scan found: [{ family, style, file, ext }].
  // stagedPath is the representative face the specimen renders.
  property string stagedPath: ""
  property var stagedFaces: []
  property string stagedTemp: ""       // extracted zip, ours to delete
  property string stagedSource: ""     // what was dropped, for the caption
  property string stagedFormat: "all"  // "all" | "otf" | "ttf"

  // True from the moment something is handed to stage() until fc-scan has
  // answered. Distinct from stagedPath, which only exists once it resolves.
  readonly property bool staging: stagePrep.running || stageScan.running

  // Desktop font formats only. Web formats (woff/woff2) turn up in downloaded
  // packs constantly and are no use installed -- fontconfig will index them,
  // then most toolkits ignore them, so they only pad the family list.
  function isDesktopFont(path) {
    return /\.(ttf|otf|ttc)$/i.test(path)
  }

  readonly property var stagedSelected: {
    var out = []
    for (var i = 0; i < root.stagedFaces.length; i++) {
      var f = root.stagedFaces[i]
      if (root.stagedFormat === "otf" && f.ext !== "otf") continue
      if (root.stagedFormat === "ttf" && f.ext !== "ttf") continue
      out.push(f)
    }
    return out
  }

  readonly property var stagedFamilies: {
    var seen = ({}), out = []
    for (var i = 0; i < root.stagedSelected.length; i++) {
      var n = root.stagedSelected[i].family
      if (!seen[n]) { seen[n] = true; out.push(n) }
    }
    out.sort()
    return out
  }

  readonly property int stagedOtfCount: {
    var n = 0
    for (var i = 0; i < root.stagedFaces.length; i++)
      if (root.stagedFaces[i].ext === "otf") n++
    return n
  }
  readonly property int stagedTtfCount: {
    var n = 0
    for (var i = 0; i < root.stagedFaces.length; i++)
      if (root.stagedFaces[i].ext !== "otf") n++
    return n
  }

  // One directory per stage, named for what the families have in common --
  // "Gotham" for a pack that declares Gotham, Gotham Black, Gotham Light and
  // so on. That is the unit a person means by "the family", and it keeps a
  // 25-file download from strewing ten folders through the font directory.
  readonly property string stagedGroup: {
    var fams = root.stagedFamilies
    if (!fams.length) return ""
    if (fams.length === 1) return fams[0]
    var words = fams[0].split(" ")
    var common = []
    for (var w = 0; w < words.length; w++) {
      var ok = true
      for (var i = 1; i < fams.length; i++) {
        var other = fams[i].split(" ")
        if (other.length <= w || other[w] !== words[w]) { ok = false; break }
      }
      if (!ok) break
      common.push(words[w])
    }
    return common.length ? common.join(" ") : fams[0]
  }


  // True once the staged file's family is already present on disk. Turns the
  // Install button into a labelled no-op rather than silently overwriting.
  // True when every family in the stage is already on disk -- so a re-drop of
  // something you already have says so instead of looking like a fresh find.
  readonly property bool stagedInstalled: {
    var fams = root.stagedFamilies
    if (!fams.length) return false
    for (var i = 0; i < fams.length; i++)
      if (root.installedNames[fams[i]] !== true) return false
    return true
  }

  // One index, rebuilt when the font list changes, so the per-item lookups
  // above and the install list below are hash hits rather than a scan of the
  // whole collection each time.
  readonly property var installedNames: {
    var m = ({})
    for (var i = 0; i < root.families.length; i++) m[root.families[i].name] = true
    return m
  }

  readonly property var stagedFamilyCounts: {
    var m = ({})
    for (var i = 0; i < root.stagedSelected.length; i++) {
      var n = root.stagedSelected[i].family
      m[n] = (m[n] || 0) + 1
    }
    return m
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
    if (root.loadedFamily) return root.loadedFamily
    return root.selected ? root.selected.name : ""
  }

  // What the heading says. For a staged pack that is the group name ("Gotham"),
  // not whichever single face happens to render the specimen.
  readonly property string previewTitle: {
    if (root.stagedFaces.length) return root.stagedGroup || root.previewFamily
    return root.previewFamily
  }

  // Wrapped in a Loader rather than bound straight to a possibly-empty source:
  // FontLoader logs "Cannot load font" for an empty URL, and a panel that
  // spams the shell log every time nothing is selected is a panel nobody will
  // keep installed. Deactivating also drops the stale family name, so the
  // heading cannot keep naming a font that is no longer staged.
  Loader {
    id: fontLoaderHost
    active: root.previewFile !== ""
    sourceComponent: FontLoader { source: "file://" + root.previewFile }
  }

  readonly property string loadedFamily: {
    if (!fontLoaderHost.item) return ""
    return fontLoaderHost.item.name || ""
  }

  // Families that can actually set Latin text, per fontconfig's own language
  // coverage. Only these get their name drawn in their own face in the list:
  // an icon font or a Tamil font would otherwise render "Font Awesome 7 Free"
  // as a row of unrelated symbols, which reads as a rendering bug. Matters
  // most with coverage fonts shown, where ~300 such rows would be unreadable.
  //
  // Not perfect: the legacy PostScript symbol faces (Dingbats, Symbol) map
  // their glyphs onto ASCII codepoints, so fontconfig credits them with
  // English and they still self-describe in symbols. That is arguably the
  // honest result -- you can see at a glance what kind of font it is.
  property var latinFamilies: ({})

  Process {
    id: latinScanner
    command: ["sh", "-c", root.boundedScanScript, "omafont-latin",
              "%{family[0]}\n", String(root.scanCap + 1), "fc-list", ":lang=en"]
    stdout: StdioCollector {
      onStreamFinished: {
        var map = ({})
        var lines = this.text.split("\n")
        var cap = Math.min(lines.length, 40000)
        for (var i = 0; i < cap; i++) {
          var n = lines[i].trim()
          if (n) map[n] = true
        }
        root.latinFamilies = map
      }
    }
  }

  function setsLatin(name) {
    return root.latinFamilies[name] === true
  }


  // ---- Browse: free fonts from Fontsource --------------------------------
  // Fontsource is a packaging of Google Fonts and friends: 2100 families, no
  // API key, and every one under OFL, Apache, UFL, MIT or Unlicense -- so
  // redistribution is actually permitted, which is the part that matters when
  // an app installs them for you.
  property var catalogue: []
  property bool catalogueLoading: false
  property string catalogueError: ""
  property string browseFilter: ""
  property string browseSelectedId: ""
  property string browsePreviewFile: ""
  property string browseTemp: ""
  property bool browseBusy: false

  readonly property int catalogueCap: 4194304
  readonly property int catalogueMaxAge: 86400

  readonly property string catalogueScript: [
    'set -eu',
    '# Catalogue fetch, cached on disk. Bounded three ways: a wall-clock timeout,',
    '# a hard byte ceiling from curl itself, and a read ceiling on the way in.',
    'cache="$1"; cap="$2"; maxage="$3"',
    'if [ -f "$cache" ]; then',
    '  age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))',
    '  if [ "$age" -lt "$maxage" ]; then',
    '    head -c "$cap" "$cache"',
    '    exit 0',
    '  fi',
    'fi',
    'mkdir -p -- "$(dirname -- "$cache")"',
    'tmp="$cache.$$"',
    '# --proto and --proto-redir pin https across redirects too, so a redirect',
    '# cannot downgrade the transport.',
    'if curl -sL --proto \'=https\' --proto-redir \'=https\' --tlsv1.2 \\',
    '     --max-time 30 --max-filesize 8388608 \\',
    '     -o "$tmp" "https://api.fontsource.org/v1/fonts"; then',
    '  if head -c 1 "$tmp" | grep -q "\\["; then',
    '    mv -- "$tmp" "$cache"',
    '    head -c "$cap" "$cache"',
    '    exit 0',
    '  fi',
    'fi',
    'rm -f -- "$tmp"',
    '# A stale cache beats no list at all when the network is down.',
    'if [ -f "$cache" ]; then head -c "$cap" "$cache"; exit 0; fi',
    'echo "could not reach the font catalogue" >&2',
    'exit 2'
  ].join("\n")

  readonly property string downloadScript: [
    'set -eu',
    '# args: destdir id subset cacheroot  then WEIGHT STYLE pairs',
    '#',
    '# URLs are BUILT here from validated components, never taken from a response.',
    '# Every id and subset matches [a-z0-9-]+, every weight is numeric and every',
    '# style is normal|italic, so the host cannot be influenced by what a server',
    '# returns. The resolved version is held to [0-9.] for the same reason.',
    'dest="$1"; id="$2"; subset="$3"; cacheroot="$4"; shift 4',
    'case "$id" in ""|*[!a-z0-9-]*) echo "bad font id" >&2; exit 2 ;; esac',
    'case "$subset" in ""|*[!a-z0-9-]*) echo "bad subset" >&2; exit 2 ;; esac',
    '',
    '# Resolve an EXACT version rather than fetching @latest. @latest is mutable:',
    '# the bytes behind that URL can change under you. A pinned version cannot.',
    '# Cached for a day so this costs one request per family, not per download.',
    'ver=""',
    'vcache="$cacheroot/versions/$id"',
    'if [ -f "$vcache" ]; then',
    '  vage=$(( $(date +%s) - $(stat -c %Y "$vcache" 2>/dev/null || echo 0) ))',
    '  if [ "$vage" -lt 86400 ]; then ver=$(head -c 32 "$vcache" 2>/dev/null || echo ""); fi',
    'fi',
    'if [ -z "$ver" ]; then',
    '  vjson=$(curl -sL --proto \'=https\' --proto-redir \'=https\' --tlsv1.2 \\',
    '    --max-time 20 --max-filesize 1048576 \\',
    '    "https://registry.npmjs.org/@fontsource/$id/latest" 2>/dev/null) || vjson=""',
    '  ver=$(printf %s "$vjson" | jq -r \'.version // empty\' 2>/dev/null || echo "")',
    '  if [ -n "$ver" ]; then',
    '    mkdir -p -- "$cacheroot/versions"',
    '    printf %s "$ver" > "$vcache" 2>/dev/null || true',
    '  fi',
    'fi',
    '# Anything but digits and dots is refused outright rather than sanitised --',
    '# a version is the one component here that comes from a response body.',
    'case "$ver" in ""|*[!0-9.]*) ver="latest" ;; esac',
    '',
    'mkdir -p -- "$dest"',
    'n=0',
    'while [ $# -ge 2 ]; do',
    '  w="$1"; st="$2"; shift 2',
    '  case "$w" in ""|*[!0-9]*) continue ;; esac',
    '  case "$st" in normal|italic) ;; *) continue ;; esac',
    '  out="$dest/$id-$subset-$w-$st.ttf"',
    '  if ! curl -sL --proto \'=https\' --proto-redir \'=https\' --tlsv1.2 \\',
    '       --max-time 45 --max-filesize 10485760 -o "$out" \\',
    '       "https://cdn.jsdelivr.net/fontsource/fonts/$id@$ver/$subset-$w-$st.ttf"; then',
    '    rm -f -- "$out"',
    '    continue',
    '  fi',
    '  # Whatever arrived must actually parse as a font before it is allowed near',
    '  # the font directory. A 200 response is not evidence of anything.',
    '  if ! fc-scan --format="%{family[0]}" "$out" 2>/dev/null | grep -q .; then',
    '    rm -f -- "$out"',
    '    continue',
    '  fi',
    '  n=$((n+1))',
    'done',
    '[ "$n" -gt 0 ] || { echo "nothing downloaded" >&2; exit 2; }',
    'printf "%s\\n" "$n"'
  ].join("\n")

  readonly property var browseSelected: {
    var src = root.browseSource === "nerd" ? root.nerdFonts : root.catalogue
    for (var i = 0; i < src.length; i++)
      if (src[i].id === root.browseSelectedId) return src[i]
    return null
  }

  readonly property var browseRows: {
    var f = root.browseFilter.toLowerCase()
    var out = []
    for (var i = 0; i < root.catalogue.length && out.length < 600; i++) {
      var c = root.catalogue[i]
      if (f && c.family.toLowerCase().indexOf(f) < 0) continue
      out.push(c)
    }
    return out
  }

  // The four faces almost anyone actually wants, filtered to what the family
  // really ships. "Every weight" is a separate, explicit action.
  function browseCoreFaces(fam) {
    if (!fam) return []
    var want = [[400, "normal"], [700, "normal"], [400, "italic"], [700, "italic"]]
    var out = []
    for (var i = 0; i < want.length; i++) {
      var w = want[i][0], st = want[i][1]
      if (fam.weights.indexOf(w) < 0) continue
      if (fam.styles.indexOf(st) < 0) continue
      out.push([w, st])
    }
    // A family with no 400 (some display faces start at 700) still needs a face.
    if (!out.length && fam.weights.length)
      out.push([fam.weights[0], fam.styles.indexOf("normal") >= 0 ? "normal" : fam.styles[0]])
    return out
  }

  function browseAllFaces(fam) {
    if (!fam) return []
    var out = []
    for (var i = 0; i < fam.weights.length; i++)
      for (var j = 0; j < fam.styles.length; j++) {
        if (out.length >= root.maxFaces) return out
        out.push([fam.weights[i], fam.styles[j]])
      }
    return out
  }


  // ---- Browse: Nerd Fonts ------------------------------------------------
  // The patched terminal fonts, one zip per family off the GitHub release.
  // Worth a source of its own here: on this desktop they are the fonts people
  // actually go looking for, and installing them by hand means finding the
  // release page, picking among 73 archives and unpacking it yourself.
  property var nerdFonts: []
  property string nerdTag: ""

  readonly property string nerdScript: [
    'set -eu',
    '# Nerd Fonts ship as one zip per family on a GitHub release. Cached, because',
    '# unauthenticated GitHub API calls are rate limited to 60/hour per address.',
    'cache="$1"; cap="$2"; maxage="$3"',
    'if [ -f "$cache" ]; then',
    '  age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))',
    '  if [ "$age" -lt "$maxage" ]; then head -c "$cap" "$cache"; exit 0; fi',
    'fi',
    'mkdir -p -- "$(dirname -- "$cache")"',
    'tmp="$cache.$$"',
    'if curl -sL --proto \'=https\' --proto-redir \'=https\' --tlsv1.2 \\',
    '     --max-time 30 --max-filesize 8388608 \\',
    '     -H "Accept: application/vnd.github+json" \\',
    '     -o "$tmp" "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest"; then',
    '  if head -c 1 "$tmp" | grep -q "{"; then',
    '    mv -- "$tmp" "$cache"; head -c "$cap" "$cache"; exit 0',
    '  fi',
    'fi',
    'rm -f -- "$tmp"',
    'if [ -f "$cache" ]; then head -c "$cap" "$cache"; exit 0; fi',
    'echo "could not reach the Nerd Fonts release list" >&2',
    'exit 2'
  ].join("\n")

  readonly property string zipDownloadScript: [
    'set -eu',
    '# args: destdir tag asset maxbytes',
    '#',
    '# Downloads to the DISK cache, never $XDG_RUNTIME_DIR: these archives run to',
    '# hundreds of megabytes and the runtime dir is tmpfs, so a large one there',
    '# would be paid for in RAM.',
    '#',
    '# The URL is built from a tag matching ^v[0-9.]+$ and an asset name matching',
    '# [A-Za-z0-9._-]+, both checked here -- nothing the API returns reaches curl',
    '# unvalidated.',
    'dest="$1"; tag="$2"; asset="$3"; maxbytes="$4"',
    'case "$tag" in ""|*[!v0-9.]*) echo "bad release tag" >&2; exit 2 ;; esac',
    'case "$asset" in ""|*[!A-Za-z0-9._-]*) echo "bad asset name" >&2; exit 2 ;; esac',
    'case "$asset" in *..*) echo "bad asset name" >&2; exit 2 ;; esac',
    'case "$maxbytes" in ""|*[!0-9]*) maxbytes=134217728 ;; esac',
    'mkdir -p -- "$dest"',
    'out="$dest/$asset"',
    'rm -f -- "$out"',
    'if ! curl -sL --proto \'=https\' --proto-redir \'=https\' --tlsv1.2 \\',
    '     --max-time 900 --max-filesize "$maxbytes" -o "$out" \\',
    '     "https://github.com/ryanoasis/nerd-fonts/releases/download/$tag/$asset"; then',
    '  rm -f -- "$out"',
    '  echo "download failed or exceeded the size limit" >&2',
    '  exit 2',
    'fi',
    '# Must be a zip before anything else touches it.',
    'if ! head -c 2 "$out" | grep -q "PK"; then',
    '  rm -f -- "$out"',
    '  echo "that download was not an archive" >&2',
    '  exit 2',
    'fi',
    'printf "%s\\n" "$out"'
  ].join("\n")


  // Nothing here runs on open. Every network call below is started by an
  // explicit click -- loading the list, previewing a face, installing a family.
  // A font panel that quietly fetches megabytes because you opened it is doing
  // something you did not ask for.
  property bool browseLoaded: false
  property string tab: "installed"           // "installed" | "browse"
  property string browseSource: "fontsource" // "fontsource" | "nerd"

  readonly property var browseList: {
    var src = root.browseSource === "nerd" ? root.nerdFonts : root.catalogue
    var f = root.browseFilter.toLowerCase()
    var out = []
    for (var i = 0; i < src.length && out.length < 800; i++) {
      if (f && src[i].family.toLowerCase().indexOf(f) < 0) continue
      out.push(src[i])
    }
    return out
  }

  Process {
    id: catalogueFetch
    stderr: StdioCollector {}
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var arr = JSON.parse(this.text)
          if (!Array.isArray(arr)) return
          var out = []
          for (var i = 0; i < arr.length && out.length < 5000; i++) {
            var e = arr[i]
            if (!e || typeof e.id !== "string" || typeof e.family !== "string") continue
            if (!/^[a-z0-9-]+$/.test(e.id)) continue
            out.push({
              id: e.id, family: e.family,
              category: String(e.category || ""),
              license: String(e.license || ""),
              subset: /^[a-z0-9-]+$/.test(String(e.defSubset || "")) ? e.defSubset : "latin",
              weights: Array.isArray(e.weights) ? e.weights : [400],
              styles: Array.isArray(e.styles) ? e.styles : ["normal"],
              source: "fontsource", bytes: 0
            })
          }
          out.sort(function(a, b) {
            var an = a.family.toLowerCase(), bn = b.family.toLowerCase()
            return an < bn ? -1 : (an > bn ? 1 : 0)
          })
          root.catalogue = out
        } catch (e) {
          root.catalogueError = "The font list came back unreadable"
        }
      }
    }
    onExited: function(code) {
      root.catalogueLoading = false
      if (code !== 0) {
        var m = catalogueFetch.stderr && catalogueFetch.stderr.text ? catalogueFetch.stderr.text.trim() : ""
        root.catalogueError = m ? m : "Could not reach the font catalogue"
      }
    }
  }

  Process {
    id: nerdFetch
    stderr: StdioCollector {}
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var rel = JSON.parse(this.text)
          if (!rel || !Array.isArray(rel.assets)) return
          if (!/^v[0-9.]+$/.test(String(rel.tag_name || ""))) return
          root.nerdTag = rel.tag_name
          var out = []
          for (var i = 0; i < rel.assets.length && out.length < 500; i++) {
            var a = rel.assets[i]
            var n = String(a.name || "")
            if (!/^[A-Za-z0-9._-]+\.zip$/.test(n)) continue
            out.push({
              id: n, family: n.replace(/\.zip$/, ""),
              category: "nerd font", license: "see upstream",
              asset: n, bytes: Number(a.size) || 0,
              source: "nerd", weights: [], styles: [], subset: ""
            })
          }
          out.sort(function(a, b) {
            var an = a.family.toLowerCase(), bn = b.family.toLowerCase()
            return an < bn ? -1 : (an > bn ? 1 : 0)
          })
          root.nerdFonts = out
        } catch (e) {
          root.catalogueError = "The Nerd Fonts list came back unreadable"
        }
      }
    }
    onExited: function(code) {
      root.catalogueLoading = false
      if (code !== 0) {
        var m = nerdFetch.stderr && nerdFetch.stderr.text ? nerdFetch.stderr.text.trim() : ""
        root.catalogueError = m ? m : "Could not reach the Nerd Fonts list"
      }
    }
  }

  // Downloads faces into a temp folder, then hands that folder to the SAME
  // staging path a dropped folder uses -- so a download previews, lists its
  // families and installs through code that is already tested.
  Process {
    id: faceDownload
    stderr: StdioCollector {}
    onExited: function(code) {
      root.browseBusy = false
      if (code === 0 && root.browseTemp) {
        // Hand off to the installed tab's staged view: it already previews,
        // lists families and installs. No second install path to get wrong.
        root.tab = "installed"
        root.stage(root.browseTemp)
      } else {
        root.autoInstall = false
        var m = faceDownload.stderr && faceDownload.stderr.text ? faceDownload.stderr.text.trim() : ""
        root.status = m ? m : "Download failed"
      }
    }
  }

  Process {
    id: zipDownload
    stderr: StdioCollector {}
    stdout: StdioCollector {
      onStreamFinished: {
        var path = this.text.trim()
        if (path) root.pendingZip = path
      }
    }
    onExited: function(code) {
      root.browseBusy = false
      if (code === 0 && root.pendingZip) {
        root.tab = "installed"
        root.stage(root.pendingZip)
        root.pendingZip = ""
      } else {
        root.autoInstall = false
        var m = zipDownload.stderr && zipDownload.stderr.text ? zipDownload.stderr.text.trim() : ""
        root.status = m ? m : "Download failed"
      }
    }
  }

  property string pendingZip: ""

  // Set when a download was started from Browse. Picking a family there is
  // already a deliberate choice, so making someone confirm a second time is
  // friction, not safety -- the staging step still runs, it just does not wait
  // for a click.
  property bool autoInstall: false

  // ---- Live preview of a remote font -------------------------------------
  // One face, about 50KB, cached on disk. Fetched when a family is selected,
  // because "see it before you install it" is the whole premise of the panel
  // and a name rendered in the UI font tells you nothing about the font.
  property string browsePreviewFor: ""

  function normaliseName(n) {
    return String(n).toLowerCase().replace(/[^a-z0-9]/g, "")
  }

  // Nerd Fonts publish faces only inside their release archives, so there is
  // nothing small to fetch. Most are patched versions of a font Fontsource
  // already carries, though -- the letterforms are identical and the patch
  // adds icon glyphs -- so the base font is an honest preview if it is
  // labelled as one. 33 of 73 families have such a base.
  readonly property var nerdBaseMap: {
    var byName = ({})
    for (var i = 0; i < root.catalogue.length; i++)
      byName[root.normaliseName(root.catalogue[i].family)] = root.catalogue[i]
    var m = ({})
    for (var j = 0; j < root.nerdFonts.length; j++) {
      var base = byName[root.normaliseName(root.nerdFonts[j].family)]
      if (base) m[root.nerdFonts[j].id] = base
    }
    return m
  }

  readonly property var browsePreviewBase: {
    var sel = root.browseSelected
    if (!sel) return null
    if (sel.source !== "nerd") return sel
    return root.nerdBaseMap[sel.id] || null
  }

  readonly property bool browsePreviewIsBase: {
    var sel = root.browseSelected
    return sel !== null && sel.source === "nerd" && root.browsePreviewBase !== null
  }

  Process {
    id: previewDownload
    onExited: function(code) {
      if (code === 0 && root.browsePreviewFor)
        root.browsePreviewFile = root.pendingPreviewPath
    }
  }

  property string pendingPreviewPath: ""

  function previewBrowseFont() {
    var base = root.browsePreviewBase
    // Already showing this one -- the signal can fire again when the catalogue
    // is reassigned, and refetching on every such tick would be wasteful.
    if (base && base.id === root.browsePreviewFor && root.browsePreviewFile !== "") return
    root.browsePreviewFile = ""
    if (!base) { root.browsePreviewFor = ""; return }
    // Prefer the regular weight; fall back to whatever the family starts at.
    var w = base.weights.indexOf(400) >= 0 ? 400 : base.weights[0]
    var st = base.styles.indexOf("normal") >= 0 ? "normal" : base.styles[0]
    if (!w || !st) { root.browsePreviewFor = ""; return }
    var dir = root.cacheRoot + "/preview"
    root.browsePreviewFor = base.id
    root.pendingPreviewPath = dir + "/" + base.id + "-" + base.subset + "-" + w + "-" + st + ".ttf"
    previewDownload.command = ["sh", "-c", root.downloadScript, "omafont-preview",
                               dir, base.id, base.subset, root.cacheRoot,
                               String(w), String(st)]
    previewDownload.running = true
  }

  // Keyed off the RESOLVED base, not the selection: a deep link sets the
  // selection before the catalogue has arrived, so a handler on the id alone
  // runs once against an empty list and never again.
  onBrowsePreviewBaseChanged: root.previewBrowseFont()

  Loader {
    id: browseFontHost
    active: root.browsePreviewFile !== ""
    sourceComponent: FontLoader { source: "file://" + root.browsePreviewFile }
  }

  readonly property string browsePreviewFamily: {
    if (!browseFontHost.item) return ""
    return browseFontHost.item.name || ""
  }

  readonly property string cacheRoot: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omafont"

  function loadBrowse() {
    if (root.catalogueLoading) return
    root.catalogueLoading = true
    root.catalogueError = ""
    root.browseLoaded = true
    catalogueFetch.command = ["sh", "-c", root.catalogueScript, "omafont-catalogue",
                              root.cacheRoot + "/fontsource.json",
                              String(root.catalogueCap), String(root.catalogueMaxAge)]
    catalogueFetch.running = true
    nerdFetch.command = ["sh", "-c", root.nerdScript, "omafont-nerd",
                         root.cacheRoot + "/nerdfonts.json",
                         String(root.catalogueCap), String(root.catalogueMaxAge)]
    nerdFetch.running = true
  }

  function downloadFaces(fam, faces) {
    if (!fam || !faces.length || root.browseBusy) return
    root.browseBusy = true
    root.autoInstall = true
    root.status = "Downloading " + fam.family + "..."
    root.browseTemp = root.cacheRoot + "/dl/" + fam.id
    var args = ["sh", "-c", root.downloadScript, "omafont-download",
                root.browseTemp, fam.id, fam.subset, root.cacheRoot]
    for (var i = 0; i < faces.length; i++) {
      args.push(String(faces[i][0]))
      args.push(String(faces[i][1]))
    }
    faceDownload.command = args
    faceDownload.running = true
  }

  function downloadNerd(fam) {
    if (!fam || root.browseBusy || !root.nerdTag) return
    root.browseBusy = true
    root.autoInstall = true
    root.status = "Downloading " + fam.family + " (" + root.mib(fam.bytes) + ")..."
    zipDownload.command = ["sh", "-c", root.zipDownloadScript, "omafont-zip",
                           root.cacheRoot + "/dl", root.nerdTag, fam.asset,
                           String(Math.max(1048576, fam.bytes + 1048576))]
    zipDownload.running = true
  }

  function mib(n) {
    if (!n) return ""
    return (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + " MB"
  }

  // ---- Scan --------------------------------------------------------------
  // One fc-list pass gives family, style, path and spacing. spacing 100 is
  // fontconfig's mono flag, which is what gates "Set as terminal font".
  // Every subprocess read is bounded and timed out. StdioCollector has no size
  // limit of its own, so an enormous font tree -- or a path on a dead network
  // mount -- would otherwise grow or block inside the shell process, which is
  // the whole desktop. Read cap+1 bytes so truncation is detectable rather
  // than silent.
  readonly property int scanCap: 8388608
  readonly property int maxFaces: 2000

  readonly property string boundedScanScript: [
    'set -eu',
    'fmt="$1"; cap="$2"; shift 2',
    'timeout 30 "$@" --format="$fmt" 2>/dev/null | head -c "$cap"'
  ].join("\n")

  readonly property string boundedFcScanScript: [
    'set -eu',
    'fmt="$1"; cap="$2"; shift 2',
    'timeout 30 fc-scan --format="$fmt" "$@" 2>/dev/null | head -c "$cap"'
  ].join("\n")

  Process {
    id: scanner
    command: ["sh", "-c", root.boundedScanScript, "omafont-scan",
              "%{family[0]}\t%{style[0]}\t%{file}\t%{spacing}\n",
              String(root.scanCap + 1), "fc-list"]
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
    // A list that quietly stopped short reads as "there was nothing else" --
    // a worse lie than a cap. Say so instead.
    if (text.length > root.scanCap)
      root.status = "Font list truncated -- more fonts here than the panel will show"
    var lines = text.split("\n")
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
    latinScanner.running = true
    scanner.running = true
  }

  // ---- Install -----------------------------------------------------------
  // $1 source file, $2 destination subdirectory (already sanitised in QML).
  // cp -f rather than -n: re-installing a font you already have should replace
  // it, which is what every "install" button anywhere does.
  // $1 destination subdirectory (already slugged in QML), then every file to
  // install. The extension check is repeated here rather than trusted from
  // QML, so nothing but a font can be copied in whatever the caller believes.
  readonly property string installScript: [
    'set -eu',
    'sub="$1"; shift',
    '# Re-checked here rather than trusted from QML: a destination is a',
    '# single path segment, never a path.',
    'case "$sub" in',
    '  ""|*/*|*..*) echo "bad destination" >&2; exit 2 ;;',
    'esac',
    'dest="$HOME/.local/share/fonts/$sub"',
    'mkdir -p -- "$dest"',
    'n=0',
    'for f in "$@"; do',
    '  # Lowercase the extension rather than globbing fixed cases: a file named',
    '  # Mixed.TtF passes the QML side and would be silently skipped here, so',
    '  # the UI would promise more fonts than it installed.',
    '  ext=$(printf %s "${f##*.}" | tr \'[:upper:]\' \'[:lower:]\')',
    '  case "$ext" in',
    '    ttf|otf|ttc) ;;',
    '    *) continue ;;',
    '  esac',
    '  [ -f "$f" ] || continue',
    '  cp -f -- "$f" "$dest/"',
    '  n=$((n+1))',
    'done',
    '[ "$n" -gt 0 ] || { echo "no installable font files" >&2; exit 2; }',
    'fc-cache -f -- "$dest" >/dev/null 2>&1 || fc-cache -f >/dev/null 2>&1 || true',
    'printf "%s\n" "$n"'
  ].join("\n")

  Process {
    id: installer
    stderr: StdioCollector {}
    onExited: function(code) {
      root.autoInstall = false
      if (code === 0) {
        root.status = "Installed " + root.pendingLabel + " -- restart an app to use it"
        root.clearStage()
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
    // Land on a real font rather than an empty pane. A font manager whose
    // first screen is 60% void is showing you nothing you came for, and the
    // specimen is the whole point of the panel.
    // stagedPath is not set until fc-scan returns, so checking it alone lets
    // this fire between the payload arriving and the stage resolving -- the
    // rail then highlights one font while the pane previews another.
    if (!root.pendingSelect && !root.selectedName && !root.stagedPath
        && !root.staging) {
      var rows = root.rows
      for (var r = 0; r < rows.length; r++) {
        if (rows[r].header !== true) { root.selectedName = rows[r].fam.name; break }
      }
    }
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
    var faces = root.stagedSelected
    if (!faces.length) return
    var group = root.stagedGroup || root.loadedFamily || "Custom"
    root.pendingLabel = faces.length === 1
      ? group
      : group + " (" + faces.length + " fonts)"
    // Select the family the specimen was showing, so the list lands where the
    // eye already is rather than on whatever sorts first.
    root.pendingFamily = faces[0].family
    root.status = "Installing " + group + "..."
    var args = ["sh", "-c", root.installScript, "omafont-install", root.slug(group)]
    for (var i = 0; i < faces.length; i++) args.push(faces[i].file)
    installer.command = args
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
  // The panel is a WlrLayer.Overlay surface with exclusive keyboard focus,
  // which by design draws above every ordinary window -- so a file dialog
  // opens BEHIND it and cannot take the keyboard. Hide the surface for as long
  // as the picker is up, and bring it back with whatever was chosen. Lowering
  // the layer instead would fix the stacking but not the focus.
  property bool picking: false

  Process {
    id: pickerProbe
    command: ["sh", "-c", "command -v zenity >/dev/null 2>&1"]
    onExited: function(code) { root.hasPicker = (code === 0) }
  }

  Process {
    id: picker
    command: ["zenity", "--file-selection", "--multiple", "--separator=\n",
              "--title=Choose fonts, a folder, or a zip",
              "--file-filter=Fonts and archives | *.ttf *.otf *.ttc *.zip *.TTF *.OTF *.TTC *.ZIP",
              "--file-filter=All files | *"]
    stdout: StdioCollector {
      onStreamFinished: {
        var picked = []
        var lines = this.text.split("\n")
        for (var i = 0; i < lines.length; i++)
          if (lines[i].trim()) picked.push(lines[i].trim())
        if (picked.length) root.stage(picked)
      }
    }
    // onExited, not just the stdout handler: a cancelled dialog produces no
    // output at all, and the panel must come back either way.
    onExited: function(code) { root.picking = false }
  }

  // ---- Staging -----------------------------------------------------------
  // Two steps, so nothing has to be quoted into a shell string: stagePrep
  // resolves whatever was handed over into a path fc-scan can walk (extracting
  // a zip if need be), and stageScan enumerates the faces under it.
  //
  // Zips are extracted with -j, which flattens the archive. That is not just
  // tidiness: a flattened extract cannot write outside the target directory,
  // so a hostile archive's ../.. entries are inert.
  readonly property string stagePrepScript: [
    'set -eu',
    '# A shell plugin runs inside the shell process, and the extract target is',
    '# $XDG_RUNTIME_DIR -- tmpfs, i.e. RAM. An unbounded extract there does not',
    '# break this panel, it takes the desktop session down. A 204KB archive can',
    '# declare 200MB of "fonts" and unzip applies no limit of its own.',
    'MAX_BYTES=134217728',
    'MAX_ENTRIES=4000',
    'MAX_KB=$((MAX_BYTES / 1024))',
    'work=""',
    'found=0',
    'for src in "$@"; do',
    '  case "$src" in',
    '    *.zip|*.ZIP)',
    '      # Cheap gate on the declared totals. A header can lie, so this is not',
    '      # the real defence -- the measured check after extraction is.',
    '      info=$(timeout 10 unzip -Zt "$src" 2>/dev/null) || info=""',
    '      entries=$(printf %s "$info" | awk \'{print $1}\')',
    '      bytes=$(printf %s "$info" | awk \'{print $3}\')',
    '      case "$entries" in \'\'|*[!0-9]*) entries=0 ;; esac',
    '      case "$bytes" in \'\'|*[!0-9]*) bytes=0 ;; esac',
    '      if [ "$entries" -gt "$MAX_ENTRIES" ] || [ "$bytes" -gt "$MAX_BYTES" ]; then',
    '        echo "that archive is too large to unpack safely" >&2',
    '        exit 3',
    '      fi',
    '      if [ -z "$work" ]; then',
    '        work="${XDG_RUNTIME_DIR:-/tmp}/omafont-stage-$$"',
    '        rm -rf -- "$work"',
    '        mkdir -p -- "$work"',
    '        printf "TEMP %s\\n" "$work"',
    '      fi',
    '      # Backgrounded and waited on deliberately: a POSIX shell defers traps',
    '      # while a FOREGROUND child runs, so cancelling mid-extract would not',
    '      # clean up until unzip finished anyway. With wait, the signal lands.',
    '      timeout 60 unzip -C -j -qq -o "$src" \'*.ttf\' \'*.otf\' \'*.ttc\' -d "$work" >/dev/null 2>&1 &',
    '      upid=$!',
    '      trap \'kill "$upid" 2>/dev/null; rm -rf -- "$work" 2>/dev/null; exit 143\' TERM INT HUP',
    '      wait "$upid" || true',
    '      trap - TERM INT HUP',
    '      # What actually landed, which is the number that can hurt.',
    '      used=$(du -sk "$work" 2>/dev/null | awk \'{print $1}\')',
    '      case "$used" in \'\'|*[!0-9]*) used=0 ;; esac',
    '      if [ "$used" -gt "$MAX_KB" ]; then',
    '        rm -rf -- "$work"',
    '        echo "that archive expanded past the size limit" >&2',
    '        exit 3',
    '      fi',
    '      ;;',
    '    *)',
    '      [ -e "$src" ] || continue',
    '      printf "PATH %s\\n" "$src"',
    '      found=$((found+1))',
    '      ;;',
    '  esac',
    'done',
    'if [ -n "$work" ]; then',
    '  if [ -z "$(ls -A "$work" 2>/dev/null)" ]; then',
    '    rm -rf -- "$work"',
    '  else',
    '    printf "PATH %s\\n" "$work"',
    '    found=$((found+1))',
    '  fi',
    'fi',
    '[ "$found" -gt 0 ] || { echo "nothing there to install" >&2; exit 2; }'
  ].join("\n")

  Process {
    id: stagePrep
    stderr: StdioCollector {}
    stdout: StdioCollector {
      onStreamFinished: {
        var targets = []
        var lines = this.text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].indexOf("TEMP ") === 0) root.stagedTemp = lines[i].substring(5)
          else if (lines[i].indexOf("PATH ") === 0) targets.push(lines[i].substring(5))
        }
        if (!targets.length) return
        // fc-scan walks several paths in one pass, so a multi-file drop costs
        // the same as a single one.
        var cmd = ["sh", "-c", root.boundedFcScanScript, "omafont-stagescan",
                   "%{family[0]}\t%{style[0]}\t%{file}\n", String(root.scanCap + 1)]
        stageScan.command = cmd.concat(targets)
        stageScan.running = true
      }
    }
    onExited: function(code) {
      if (code !== 0) {
        var msg = stagePrep.stderr && stagePrep.stderr.text ? stagePrep.stderr.text.trim() : ""
        root.status = msg ? msg : "Could not read that"
      }
    }
  }

  Process {
    id: stageScan
    stdout: StdioCollector {
      onStreamFinished: {
        var faces = []
        var lines = this.text.split("\n")
        var cap = Math.min(lines.length, 20000)
        for (var i = 0; i < cap; i++) {
          var parts = lines[i].split("\t")
          if (parts.length < 3) continue
          var file = parts[2].trim()
          if (!root.isDesktopFont(file)) continue
          var m = file.match(/\.([A-Za-z0-9]+)$/)
          faces.push({
            family: parts[0].trim(),
            style: parts[1].trim(),
            file: file,
            ext: m ? m[1].toLowerCase() : ""
          })
        }
        if (!faces.length) {
          root.clearStage()
          root.autoInstall = false
          root.status = "No installable fonts found in that"
          return
        }
        // Every staged face becomes one argv entry at install time, and a
        // crafted folder decides how many there are -- past a point the kernel
        // refuses the exec. Cap it, and report the real total so the UI is not
        // lying about what it is holding.
        var truncated = false
        if (faces.length > root.maxFaces) {
          truncated = true
          faces = faces.slice(0, root.maxFaces)
        }
        if (this.text.length > root.scanCap) truncated = true
        faces.sort(function(a, b) {
          var an = (a.family + " " + a.style).toLowerCase()
          var bn = (b.family + " " + b.style).toLowerCase()
          return an < bn ? -1 : (an > bn ? 1 : 0)
        })
        root.stagedFaces = faces
        root.stagedFormat = "all"
        root.stagedPath = faces[0].file
        root.selectedName = ""
        root.status = truncated
          ? "Showing the first " + faces.length + " fonts -- that source holds more"
          : ""
        if (root.autoInstall) root.installStaged()
      }
    }
  }

  // Deleting a zip we extracted. Confined to our own temp prefix, and the
  // script re-checks that rather than trusting the caller.
  readonly property string cleanTempScript: [
    'set -eu',
    'd="$1"',
    '[ -n "$d" ] || exit 0',
    'case "$d" in */omafont-stage-*) ;; *) exit 0 ;; esac',
    'case "$d" in *..*) exit 0 ;; esac',
    '[ -d "$d" ] || exit 0',
    'rm -rf -- "$d"'
  ].join("\n")

  function clearStage() {
    // Stop the workers FIRST. Removing the temp tree while unzip is still
    // writing into it just leaves a fresh one behind -- in RAM, since the
    // extract target is tmpfs. The prep script also traps its own signals and
    // cleans up, so this is belt and braces.
    root.picking = false
    if (stagePrep.running) stagePrep.running = false
    if (stageScan.running) stageScan.running = false
    if (root.stagedTemp) {
      Quickshell.execDetached(["sh", "-c", root.cleanTempScript,
                               "omafont-cleanup", root.stagedTemp])
      root.stagedTemp = ""
    }
    root.stagedPath = ""
    root.stagedFaces = []
    root.stagedSource = ""
    root.stagedFormat = "all"
  }

  // Accepts a single path or a list of them -- a dropped selection, a folder,
  // a zip, or any mix of those.
  function openPicker() {
    if (!root.hasPicker || root.picking) return
    root.picking = true
    picker.running = true
  }

  function stage(paths) {
    if (!paths) return
    var list = (typeof paths === "string") ? [paths] : paths
    var clean = []
    for (var i = 0; i < list.length; i++) {
      var p = String(list[i])
      if (p.indexOf("file://") === 0) p = decodeURIComponent(p.substring(7))
      if (p) clean.push(p)
    }
    if (!clean.length) return
    root.clearStage()
    root.selectedName = ""
    root.stagedSource = clean.length === 1
      ? clean[0].split("/").pop()
      : clean.length + " items"
    root.status = "Reading " + root.stagedSource + "..."
    var cmd = ["sh", "-c", root.stagePrepScript, "omafont-stage"]
    stagePrep.command = cmd.concat(clean)
    stagePrep.running = true
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
    // The IPC payload is the least trusted input this panel has: any process
    // on the session can send one. Bound it where it arrives rather than
    // trusting the staging path to cope.
    try {
      if (payloadJson && payloadJson.length > 65536) return
      var payload = JSON.parse(payloadJson || "{}")
      if (payload && (payload.tab === "browse" || payload.tab === "installed"))
        root.tab = payload.tab
      // Deep link: open Browse at a particular family, e.g. from a keybinding.
      // Bounded and charset-checked like every other id that reaches us.
      if (payload && typeof payload.select === "string"
          && payload.select.length <= 128
          && /^[A-Za-z0-9._-]+$/.test(payload.select)) {
        root.tab = "browse"
        if (payload.source === "nerd") root.browseSource = "nerd"
        if (!root.browseLoaded) root.loadBrowse()
        root.browseSelectedId = payload.select
      }
      if (payload && payload.pick === true) { root.openPicker(); return }
      if (!payload || !payload.install) return
      var want = payload.install
      if (typeof want === "string") {
        if (want.length <= 4096) root.stage(want)
        return
      }
      if (Array.isArray(want)) {
        var paths = []
        for (var i = 0; i < want.length && paths.length < 64; i++)
          if (typeof want[i] === "string" && want[i].length <= 4096)
            paths.push(want[i])
        if (paths.length) root.stage(paths)
      }
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
    root.clearStage()
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
    visible: root.opened && !root.picking
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omafont"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: (root.opened && !root.picking)
                                 ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
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
      width: Math.min(Style.space(980), panel.width - Style.gapsOut * 2)
      height: Math.max(0, Math.min(panel.height * 0.82, panel.height - Style.gapsOut * 2))
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
            // A drag can carry an arbitrary number of URLs.
            root.stage(drop.urls.length > 64 ? drop.urls.slice(0, 64) : drop.urls)
            drop.accept()
          }
        }
      }

      // A small caption-sized label on a tinted ground. Used for provenance,
      // style count and the monospace flag, so the metadata row reads as data
      // rather than as a run-on sentence.
      component Chip: Rectangle {
        property string label: ""
        property color tint: root.foreground
        // Chips carry filenames, and a filename is as long as someone's
        // download decided it would be. Without a ceiling the pill runs past
        // the card and is hard-clipped mid-word with no ellipsis.
        property real maxWidth: Style.space(300)

        implicitWidth: Math.min(chipText.implicitWidth, maxWidth) + Style.spacing.lg * 2
        implicitHeight: chipText.implicitHeight + Style.spacing.sm * 2
        radius: height / 2
        color: Qt.rgba(tint.r, tint.g, tint.b, 0.14)

        Text {
          id: chipText
          anchors.centerIn: parent
          width: Math.min(implicitWidth, parent.maxWidth)
          // Middle rather than right: the tail of a font filename is where the
          // weight and the extension live, which is the useful half.
          elide: Text.ElideMiddle
          text: parent.label
          color: parent.tint
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
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
          } else if (event.key === Qt.Key_Q && !filterField.activeFocus && !sampleField.activeFocus) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Slash && !filterField.activeFocus && !sampleField.activeFocus) {
            filterField.forceActiveFocus()
            event.accepted = true
          } else if ((event.key === Qt.Key_R || event.key === Qt.Key_F5)
                     && !filterField.activeFocus && !sampleField.activeFocus) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
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

        // ---- Header ----
        Item {
          width: parent.width
          height: root.headerH

          Row {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Fonts"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Repeater {
              model: [{ key: "installed", label: "Installed" },
                      { key: "browse", label: "Browse" }]

              Item {
                id: tabItem
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: tabLabel.implicitWidth + Style.spacing.md * 2
                implicitHeight: tabLabel.implicitHeight + Style.spacing.sm * 2

                Rectangle {
                  anchors.fill: parent
                  radius: Math.max(2, Style.space(4))
                  color: root.tab === tabItem.modelData.key
                         ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                         : (tabMouse.containsMouse ? Style.hoverFill : "transparent")
                }

                Text {
                  id: tabLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: tabItem.modelData.label
                  color: root.tab === tabItem.modelData.key ? root.accent : root.foreground
                  opacity: root.tab === tabItem.modelData.key ? 1.0 : 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  id: tabMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.tab = tabItem.modelData.key
                }
              }
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: titleText.right
            anchors.leftMargin: Style.spacing.lg
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
            text: {
              if (root.status !== "") return root.status
              if (root.tab === "browse") {
                if (!root.browseLoaded) return ""
                if (root.catalogueLoading) return "fetching..."
                var total = root.browseSource === "nerd"
                            ? root.nerdFonts.length : root.catalogue.length
                if (!total) return ""
                return root.browseList.length === total
                       ? total + " available"
                       : root.browseList.length + " of " + total
              }
              if (root.scanning) return "Scanning..."
              if (root.hideCoverage && root.filter === "" && root.coverageCount > 0)
                return (root.families.length - root.coverageCount) + " of "
                       + root.families.length + " families"
              return root.families.length + " families"
            }
            color: root.status !== "" ? root.accent : root.foreground
            opacity: root.status !== "" ? 1.0 : 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Body: rail | divider | preview ----
        Row {
          id: body
          visible: root.tab === "installed"
          width: parent.width
          height: parent.height - root.headerH - actions.height - divider.height
                  - root.contentSpacing * 3
          spacing: root.contentSpacing

          // The rail sits on its own faintly tinted surface. One flat slab
          // divided by a rule reads as a spreadsheet; two surfaces read as a
          // browser with a canvas beside it, which is what this is.
          Rectangle {
            width: root.railWidth
            height: parent.height
            radius: Math.max(2, Style.space(6))
            // Fill alone is not enough: the kit's normalFill is ~4% alpha and
            // at true scale it is invisible against the card. The hairline
            // border is what actually separates the two surfaces, and it reads
            // in any theme because it tracks the foreground.
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            border.width: Style.spacing.hairline
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

            Column {
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            spacing: Style.spacing.sm

            TextField {
              id: filterField
              width: parent.width
              placeholderText: "Filter fonts"
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
              height: root.coverageCount > 0 ? coverageLabel.implicitHeight + Style.spacing.xs : 0
              visible: root.coverageCount > 0

              Text {
                id: coverageLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.filter !== ""
                      ? "searching all fonts"
                      : (root.hideCoverage
                         ? root.coverageCount + " language fonts hidden · show"
                         : "showing all · hide language fonts")
                color: root.filter !== "" ? root.foreground : root.accent
                opacity: root.filter !== "" ? 0.4 : (coverageMouse.containsMouse ? 1.0 : 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: coverageMouse
                anchors.fill: parent
                hoverEnabled: true
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
                readonly property bool isSelected: !rowItem.isHeader
                                                   && rowItem.fam.name === root.selectedName

                width: list.width
                height: rowItem.isHeader ? root.rowH + Style.spacing.md : root.rowH

                // Section header
                Text {
                  visible: rowItem.isHeader
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.spacing.xs
                  textFormat: Text.PlainText
                  text: rowItem.isHeader
                        ? rowItem.modelData.label.toUpperCase() + "  " + rowItem.modelData.count
                        : ""
                  color: root.foreground
                  opacity: 0.35
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }

                // Family row
                Rectangle {
                  visible: !rowItem.isHeader
                  anchors.fill: parent
                  anchors.rightMargin: Style.spacing.xxs
                  radius: Math.max(2, Style.space(4))
                  color: {
                    if (rowItem.isHeader) return "transparent"
                    if (rowItem.isSelected) return Style.selectedAccentFill
                    if (rowMouse.containsMouse) return Style.hoverFill
                    return "transparent"
                  }

                  // Accent spine on the selected row: reads at a glance in a
                  // long list where the fill alone is subtle.
                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Style.space(2)
                    radius: width
                    color: root.accent
                    visible: rowItem.isSelected
                  }

                  // The name set in its own face. This is the whole point of a
                  // font list -- reading "Nimbus Roman" in Times tells you more
                  // than any label could. Installed families are already known
                  // to Qt, so no FontLoader is needed per row.
                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.md
                    anchors.right: monoTag.left
                    anchors.rightMargin: Style.spacing.xs
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: rowItem.isHeader ? "" : rowItem.fam.name
                    color: root.foreground
                    opacity: rowItem.isSelected ? 1.0 : 0.85
                    font.family: (!rowItem.isHeader && root.setsLatin(rowItem.fam.name))
                                 ? rowItem.fam.name : root.fontFamily
                    font.pixelSize: Style.font.subtitle
                  }

                  // Monospace marker -- the only families "Set as terminal
                  // font" will accept, so it is worth showing in the list.
                  Rectangle {
                    id: monoTag
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !rowItem.isHeader && rowItem.fam.mono
                    width: Style.space(14)
                    height: Style.space(14)
                    radius: Style.space(3)
                    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)

                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: "M"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
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
          }

          // ---- Preview ----
          Item {
            width: parent.width - root.railWidth - root.contentSpacing
            height: parent.height

            // Empty state
            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(60)
              spacing: Style.spacing.md
              visible: !root.selected && !root.stagedPath

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Aa"
                color: root.foreground
                opacity: 0.16
                font.family: root.fontFamily
                font.pixelSize: Style.space(56)
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Pick a font to preview it"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: "Drop a .ttf or .otf here, or double-click one in your file manager, to preview it before installing."
                color: root.foreground
                opacity: 0.35
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
                spacing: Style.spacing.xxl

                // Name, set in its own face at display size.
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.previewTitle
                  color: root.foreground
                  // Staged fonts are not in fontconfig's index yet, so they are
                  // always drawn in their own face -- seeing the thing you are
                  // about to install is the entire point of the staged state.
                  font.family: (root.stagedPath || root.setsLatin(root.previewFamily))
                               ? root.previewFamily : root.fontFamily
                  font.pixelSize: Style.space(42)
                  // Shrink to fit rather than truncate. Eliding a heading that
                  // IS the font's name -- "Noto Sans Devanagari UI ExtraCond..."
                  // -- hides the part that distinguishes it from its siblings.
                  fontSizeMode: Text.HorizontalFit
                  minimumPixelSize: Style.space(18)
                }

                // Metadata as chips rather than a dot-joined sentence.
                Flow {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Chip {
                    visible: root.stagedPath !== ""
                    label: root.stagedInstalled ? "already installed" : "not installed"
                    tint: root.accent
                  }
                  Chip {
                    visible: root.stagedPath !== ""
                    label: root.stagedSelected.length
                           + (root.stagedSelected.length === 1 ? " font" : " fonts")
                    tint: root.foreground
                  }
                  Chip {
                    visible: root.stagedPath !== "" && root.stagedFamilies.length > 1
                    label: root.stagedFamilies.length + " families"
                    tint: root.foreground
                  }
                  Chip {
                    visible: root.stagedPath === "" && root.selected !== null
                    label: root.selected && root.selected.user ? "yours" : "system"
                    tint: root.selected && root.selected.user ? root.accent : root.foreground
                  }
                  Chip {
                    visible: root.stagedPath === "" && root.selected !== null
                    label: root.selected
                           ? root.selected.styles.length + (root.selected.styles.length === 1 ? " style" : " styles")
                           : ""
                    tint: root.foreground
                  }
                  Chip {
                    visible: root.stagedPath === "" && root.selected !== null && root.selected.mono
                    label: "monospace"
                    tint: root.foreground
                  }
                  Chip {
                    visible: root.stagedPath !== ""
                    label: root.stagedSource
                    tint: root.foreground
                  }

                  // Packs routinely ship the same faces as both OTF and TTF.
                  // Installing both leaves duplicates in every font menu, and
                  // the two formats often disagree about family names, so they
                  // cannot be deduped reliably -- let the choice be explicit.
                  Repeater {
                    model: (root.stagedPath !== "" && root.stagedOtfCount > 0
                            && root.stagedTtfCount > 0)
                           ? [{ key: "all", label: "both" },
                              { key: "otf", label: root.stagedOtfCount + " OTF" },
                              { key: "ttf", label: root.stagedTtfCount + " TTF" }]
                           : []

                    Item {
                      required property var modelData
                      implicitWidth: fmtChip.implicitWidth
                      implicitHeight: fmtChip.implicitHeight

                      Chip {
                        id: fmtChip
                        label: parent.modelData.label
                        tint: root.stagedFormat === parent.modelData.key
                              ? root.accent : root.foreground
                        opacity: root.stagedFormat === parent.modelData.key ? 1.0 : 0.55
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.stagedFormat = parent.modelData.key
                      }
                    }
                  }
                }

                // Editable specimen text. A font is chosen against the words it
                // will actually set, so the pangram is a starting point, not a
                // fixed exhibit.
                TextField {
                  id: sampleField
                  width: parent.width
                  placeholderText: root.defaultSample
                  foreground: root.foreground
                  accent: root.accent
                  verticalPadding: Style.spacing.xs
                  onTextChanged: root.sample = text.length ? text : root.defaultSample
                }

                // Specimen, size-labelled in a left gutter.
                Repeater {
                  model: root.specimenSizes

                  Row {
                    required property int modelData
                    width: preview.width
                    spacing: Style.spacing.md

                    Text {
                      textFormat: Text.PlainText
                      width: Style.space(22)
                      anchors.verticalCenter: parent.verticalCenter
                      horizontalAlignment: Text.AlignRight
                      text: parent.modelData
                      color: root.foreground
                      opacity: 0.3
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      width: parent.width - Style.space(22) - Style.spacing.md
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: root.sample
                      color: root.foreground
                      font.family: root.previewFamily
                      font.pixelSize: Style.space(parent.modelData)
                    }
                  }
                }

                // The character set on its own plate. A tinted block gives the
                // pane a second surface and stops the glyphs reading as one
                // more paragraph of sample text.
                Rectangle {
                  width: parent.width
                  height: glyphs.implicitHeight + Style.spacing.lg * 2
                  radius: Math.max(2, Style.space(6))
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                  border.width: Style.spacing.hairline
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                  Text {
                    id: glyphs
                    anchors.fill: parent
                    anchors.margins: Style.spacing.lg
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                    text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789  &@#$%*()[]{}/\\ <>?!.,;:'\"-+="
                    color: root.foreground
                    opacity: 0.8
                    font.family: root.previewFamily
                    font.pixelSize: Style.space(17)
                    lineHeight: 1.45
                  }
                }

                // What a staged pack will actually install, spelled out. A
                // batch install is worth showing in full before it happens.
                Column {
                  width: parent.width
                  spacing: Style.spacing.xxs
                  visible: root.stagedPath !== "" && root.stagedFamilies.length > 0

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: "Will install"
                    color: root.foreground
                    opacity: 0.35
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }

                  Repeater {
                    model: root.stagedFamilies

                    Text {
                      required property string modelData
                      width: preview.width
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: modelData + "  " + (root.stagedFamilyCounts[modelData] || 0)
                      color: root.foreground
                      opacity: 0.6
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "into ~/.local/share/fonts/" + root.slug(root.stagedGroup) + "/"
                    color: root.foreground
                    opacity: 0.3
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Styles in the family, as chips.
                Column {
                  width: parent.width
                  spacing: Style.spacing.sm
                  visible: !root.stagedPath && root.selected && root.selected.styles.length > 0

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: "STYLES"
                    color: root.foreground
                    opacity: 0.3
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Repeater {
                    model: root.selected ? root.selected.styles : []
                    Chip {
                      required property string modelData
                      label: modelData
                      tint: root.foreground
                    }
                  }
                }
                }
              }
            }
          }
        }


        // ---- Browse -----------------------------------------------------
        Item {
          id: browseBody
          visible: root.tab === "browse"
          width: parent.width
          height: parent.height - root.headerH - actions.height - divider.height
                  - root.contentSpacing * 3

          // Nothing has been fetched yet. Say exactly what will be downloaded
          // and let the person decide -- a panel that quietly pulls megabytes
          // because you clicked a tab is doing something you did not ask for.
          Column {
            anchors.centerIn: parent
            width: Math.min(Style.space(420), parent.width - Style.space(40))
            spacing: Style.spacing.lg
            visible: !root.browseLoaded

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "Aa"
              color: root.foreground
              opacity: 0.16
              font.family: root.fontFamily
              font.pixelSize: Style.space(56)
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: "Browse free fonts"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Fetches two lists: about 2100 open-licence families from "
                    + "Fontsource, and the Nerd Fonts release index. Roughly "
                    + "600 KB, cached for a day. No font is downloaded until "
                    + "you ask for it."
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              width: parent.width
              height: loadBtn.implicitHeight
              Button {
                id: loadBtn
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Load font list"
                bordered: true
                foreground: root.accent
                fontFamily: root.fontFamily
                onClicked: root.loadBrowse()
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              visible: root.catalogueError !== ""
              text: root.catalogueError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.browseLoaded && root.catalogueLoading
            textFormat: Text.PlainText
            text: "Fetching the font list..."
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          Row {
            anchors.fill: parent
            spacing: root.contentSpacing
            visible: root.browseLoaded && !root.catalogueLoading

            Rectangle {
              width: root.railWidth
              height: parent.height
              radius: Math.max(2, Style.space(6))
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              border.width: Style.spacing.hairline
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

              Column {
                anchors.fill: parent
                anchors.margins: Style.spacing.md
                spacing: Style.spacing.sm

                Row {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Repeater {
                    model: [{ key: "fontsource", label: "Google Fonts" },
                            { key: "nerd", label: "Nerd Fonts" }]

                    Item {
                      id: srcItem
                      required property var modelData
                      implicitWidth: srcLabel.implicitWidth + Style.spacing.md * 2
                      implicitHeight: srcLabel.implicitHeight + Style.spacing.sm * 2

                      Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: root.browseSource === srcItem.modelData.key
                               ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                               : "transparent"
                      }

                      Text {
                        id: srcLabel
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: srcItem.modelData.label
                        color: root.browseSource === srcItem.modelData.key ? root.accent : root.foreground
                        opacity: root.browseSource === srcItem.modelData.key ? 1.0 : 0.5
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.browseSource = srcItem.modelData.key
                          root.browseSelectedId = ""
                        }
                      }
                    }
                  }
                }

                TextField {
                  id: browseFilterField
                  width: parent.width
                  placeholderText: "Filter"
                  foreground: root.foreground
                  accent: root.accent
                  onTextChanged: root.browseFilter = text
                }

                ListView {
                  id: browseListView
                  width: parent.width
                  height: parent.height - browseFilterField.height
                          - Style.spacing.sm * 3 - Style.space(22)
                  clip: true
                  model: root.browseList
                  boundsBehavior: Flickable.StopAtBounds

                  delegate: Item {
                    id: bRow
                    required property var modelData
                    width: browseListView.width
                    height: root.rowH

                    Rectangle {
                      anchors.fill: parent
                      anchors.rightMargin: Style.spacing.xxs
                      radius: Math.max(2, Style.space(4))
                      color: bRow.modelData.id === root.browseSelectedId
                             ? Style.selectedAccentFill
                             : (bMouse.containsMouse ? Style.hoverFill : "transparent")

                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Style.space(2)
                        radius: width
                        color: root.accent
                        visible: bRow.modelData.id === root.browseSelectedId
                      }

                      Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.spacing.md
                        anchors.right: bMeta.left
                        anchors.rightMargin: Style.spacing.xs
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: bRow.modelData.family
                        color: root.foreground
                        opacity: 0.85
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        id: bMeta
                        anchors.right: parent.right
                        anchors.rightMargin: Style.spacing.sm
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: bRow.modelData.source === "nerd"
                              ? root.mib(bRow.modelData.bytes)
                              : bRow.modelData.category
                        color: root.foreground
                        opacity: 0.35
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        id: bMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.browseSelectedId = bRow.modelData.id
                      }
                    }
                  }
                }

                Text {
                  width: parent.width
                  height: Style.space(18)
                  verticalAlignment: Text.AlignVCenter
                  textFormat: Text.PlainText
                  text: root.browseList.length + " of "
                        + (root.browseSource === "nerd" ? root.nerdFonts.length : root.catalogue.length)
                  color: root.foreground
                  opacity: 0.3
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Item {
              width: parent.width - root.railWidth - root.contentSpacing
              height: parent.height

              Text {
                anchors.centerIn: parent
                visible: !root.browseSelected
                textFormat: Text.PlainText
                text: "Pick a font to see what it installs"
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.spacing.xl
                visible: root.browseSelected !== null

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.browseSelected ? root.browseSelected.family : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(42)
                  fontSizeMode: Text.HorizontalFit
                  minimumPixelSize: Style.space(18)
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Chip {
                    visible: root.browseSelected && root.browseSelected.license !== ""
                    label: root.browseSelected ? root.browseSelected.license : ""
                    tint: root.accent
                  }
                  Chip {
                    visible: root.browseSelected && root.browseSelected.category !== ""
                    label: root.browseSelected ? root.browseSelected.category : ""
                    tint: root.foreground
                  }
                  Chip {
                    visible: root.browseSelected && root.browseSelected.source === "fontsource"
                    label: root.browseSelected
                           ? root.browseSelected.weights.length + " weights" : ""
                    tint: root.foreground
                  }
                  Chip {
                    visible: root.browseSelected && root.browseSelected.source === "nerd"
                    label: root.browseSelected ? root.mib(root.browseSelected.bytes) : ""
                    tint: root.foreground
                  }
                }

                // Live specimen, rendered from the face actually fetched.
                Column {
                  width: parent.width
                  spacing: Style.spacing.md
                  visible: root.browsePreviewFamily !== ""

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    visible: root.browsePreviewIsBase
                    text: "PREVIEWING THE UNPATCHED BASE FONT"
                    color: root.foreground
                    opacity: 0.35
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }

                  Repeater {
                    model: [40, 26, 17]

                    Text {
                      required property int modelData
                      width: parent ? parent.width : 0
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: root.sample
                      color: root.foreground
                      font.family: root.browsePreviewFamily
                      font.pixelSize: Style.space(modelData)
                    }
                  }

                  Text {
                    width: parent.width
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                    text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789"
                    color: root.foreground
                    opacity: 0.7
                    font.family: root.browsePreviewFamily
                    font.pixelSize: Style.space(15)
                    lineHeight: 1.4
                  }
                }

                // Why there is no specimen, when there is not one.
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  visible: root.browsePreviewFamily === "" && root.browseSelected !== null
                  text: root.browseSelected && root.browseSelected.source === "nerd"
                        && !root.browsePreviewBase
                        ? "No preview: Nerd Fonts are published only inside their release archives, and this one has no unpatched base font on Fontsource."
                        : "Fetching a sample face..."
                  color: root.foreground
                  opacity: 0.4
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.browseSelected && root.browseSelected.source === "nerd"
                        ? "Downloads the family archive and installs every face it contains."
                        : "Downloads and installs these faces into ~/.local/share/fonts."
                  color: root.foreground
                  opacity: 0.4
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Button {
                    text: root.browseBusy
                          ? "Working..."
                          : (root.browseSelected && root.browseSelected.source === "nerd"
                             ? "Install (" + root.mib(root.browseSelected.bytes) + " download)"
                             : "Install "
                               + (root.browseSelected ? root.browseCoreFaces(root.browseSelected).length : 0)
                               + " faces")
                    bordered: true
                    enabled: !root.browseBusy
                    opacity: root.browseBusy ? 0.5 : 1.0
                    foreground: root.accent
                    fontFamily: root.fontFamily
                    onClicked: {
                      if (!root.browseSelected) return
                      if (root.browseSelected.source === "nerd") root.downloadNerd(root.browseSelected)
                      else root.downloadFaces(root.browseSelected,
                                              root.browseCoreFaces(root.browseSelected))
                    }
                  }

                  Button {
                    text: "Install every weight"
                    bordered: true
                    visible: root.browseSelected && root.browseSelected.source === "fontsource"
                    enabled: !root.browseBusy
                    opacity: root.browseBusy ? 0.5 : 1.0
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: {
                      if (!root.browseSelected) return
                      root.downloadFaces(root.browseSelected,
                                         root.browseAllFaces(root.browseSelected))
                    }
                  }
                }
              }
            }
          }
        }

        Rectangle {
          id: divider
          width: parent.width
          height: Style.spacing.hairline
          color: root.foreground
          opacity: 0.12
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
              text: root.stagedSelected.length > 1
                    ? "Install " + root.stagedSelected.length + " fonts"
                    : "Install"
              bordered: true
              visible: root.stagedPath !== ""
              foreground: root.accent
              fontFamily: root.fontFamily
              onClicked: root.installStaged()
            }

            Button {
              text: "Cancel"
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
              onClicked: root.openPicker()
            }

            Button {
              text: "Set as terminal font"
              bordered: true
              visible: root.stagedPath === "" && root.selected !== null && root.selected.mono
              foreground: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setAsMono()
            }
          }

          Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Remove"
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
