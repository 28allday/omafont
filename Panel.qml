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

  // Injected by the host when a plugin declares it (shell.qml sets omarchyPath
  // on any target that has the property); the env var is the fallback.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string omarchyBin: root.omarchyPath + "/bin"
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
    command: ["/bin/sh", "-c", root.boundedScanScript, "omafont-latin",
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
    '# The shell process inherits a PATH with user-writable directories ahead',
    '# of /usr/bin, so every bare command name here would be substitutable.',
    '# Pin it before running anything.',
    'PATH=/usr/local/bin:/usr/bin:/bin',
    'export PATH',
    'fmt="$1"; cap="$2"; shift 2',
    'timeout 30 "$@" --format="$fmt" 2>/dev/null | head -c "$cap"'
  ].join("\n")

  readonly property string boundedFcScanScript: [
    'set -eu',
    '# The shell process inherits a PATH with user-writable directories ahead',
    '# of /usr/bin, so every bare command name here would be substitutable.',
    '# Pin it before running anything.',
    'PATH=/usr/local/bin:/usr/bin:/bin',
    'export PATH',
    'fmt="$1"; cap="$2"; shift 2',
    'timeout 30 fc-scan --format="$fmt" "$@" 2>/dev/null | head -c "$cap"'
  ].join("\n")

  Process {
    id: scanner
    command: ["/bin/sh", "-c", root.boundedScanScript, "omafont-scan",
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

  // ---- Filesystem operations ---------------------------------------------
  // install / remove / cleantemp, in one program rather than three shell
  // scripts, because all three need the same thing: every directory opened
  // relative to a descriptor already held, with O_NOFOLLOW, instead of being
  // re-walked by pathname between the check and the use.
  //
  // A pathname check cannot be made safe here. `[ -L "$dest" ]` followed by
  // `cp` is two separate resolutions of the same name, and the destination --
  // or any parent of it -- can be replaced with a symlink in between; the
  // shell has no openat, so there is no way to say "the directory I just
  // checked" rather than "whatever this name means now". Holding the
  // descriptor is what closes that, so the operations that write live here.
  //
  // Verb first, then its arguments: install takes the destination
  // subdirectory (already slugged in QML, re-validated here) and every file
  // to install; remove takes absolute paths under the user font root;
  // cleantemp takes one staging directory. Nothing is trusted from QML --
  // the extension check, the single-segment destination and the font-root
  // prefix are all repeated on this side.
  //
  // Re-installing a font you already have replaces it (O_TRUNC), which is
  // what every "install" button anywhere does.
  readonly property string fsOpsProgram: [
    'import os, stat, subprocess, sys',
    '# One helper for every path that WRITES, so the descriptor walk below exists',
    '# once instead of three times. Invoked by absolute path from the panel, so',
    '# nothing here resolves through the shell process\'s user-writable PATH;',
    '# fc-cache is the only child and it is given an explicit environment.',
    'SAFE_PATH = "/usr/local/bin:/usr/bin:/bin"',
    'EXTS = (".ttf", ".otf", ".ttc")',
    'FONT_DIR = (".local", "share", "fonts")',
    '',
    'def die(msg, code=2):',
    '    sys.stderr.write(msg + "\\n")',
    '    raise SystemExit(code)',
    '',
    'def home_dir():',
    '    h = os.environ.get("HOME") or ""',
    '    if not h.startswith("/"):',
    '        die("no home directory")',
    '    return h',
    '',
    'def opendir(parent_fd, name, create=False):',
    '    # openat(name, O_DIRECTORY|O_NOFOLLOW) relative to a descriptor already',
    '    # held. O_NOFOLLOW is the point: a symlink at `name` fails with ELOOP',
    '    # rather than quietly redirecting the operation somewhere else, and',
    '    # because each component is opened relative to the previous descriptor',
    '    # instead of being re-walked by pathname, nothing above us can be',
    '    # swapped after it has been checked.',
    '    if create:',
    '        try:',
    '            os.mkdir(name, 0o755, dir_fd=parent_fd)',
    '        except FileExistsError:',
    '            pass',
    '        except OSError as e:',
    '            die("cannot create %s (%s)" % (name, e.strerror))',
    '    try:',
    '        return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,',
    '                       dir_fd=parent_fd)',
    '    except OSError as e:',
    '        die("refusing to follow %s: expected a real directory (%s)"',
    '            % (name, e.strerror))',
    '',
    'def walk(base_fd, comps, create=False):',
    '    fds, cur = [], base_fd',
    '    for c in comps:',
    '        cur = opendir(cur, c, create=create)',
    '        fds.append(cur)',
    '    return cur, fds',
    '',
    'def closeall(fds):',
    '    for fd in fds:',
    '        try:',
    '            os.close(fd)',
    '        except OSError:',
    '            pass',
    '',
    'def seg_ok(s):',
    '    return s and s not in (".", "..") and "/" not in s and "\\0" not in s',
    '',
    'def fc_cache(target=None):',
    '    # fc-cache only builds an index -- it writes no user content -- so it sits',
    '    # outside the trust boundary the descriptors establish. When a target is',
    '    # given it is read back off the descriptor actually written to rather than',
    '    # rebuilt from $HOME, so it names the real directory even if the pathname',
    '    # was swapped underneath us. The descriptor cannot be passed directly:',
    '    # fontconfig keys its cache on the directory it is handed, so a',
    '    # /proc/self/fd path would index the fonts under a name that stops',
    '    # existing the moment this process exits.',
    '    env = {"PATH": SAFE_PATH, "HOME": home_dir()}',
    '    cmd = ["fc-cache", "-f"] + (["--", target] if target else [])',
    '    try:',
    '        subprocess.call(cmd, env=env, stdout=subprocess.DEVNULL,',
    '                        stderr=subprocess.DEVNULL, timeout=120)',
    '    except Exception:',
    '        pass',
    '',
    'def do_install(argv):',
    '    sub = argv[0] if argv else ""',
    '    # A destination is a single path segment, never a path. Re-checked here',
    '    # rather than trusted from the QML slug.',
    '    if not seg_ok(sub):',
    '        die("bad destination")',
    '    home = home_dir()',
    '    fds = []',
    '    n = 0',
    '    try:',
    '        base = os.open(home, os.O_RDONLY | os.O_DIRECTORY)',
    '        fds.append(base)',
    '        fonts_fd, more = walk(base, FONT_DIR, create=True)',
    '        fds += more',
    '        fam_fd = opendir(fonts_fd, sub, create=True)',
    '        fds.append(fam_fd)',
    '        for src in argv[1:]:',
    '            if os.path.splitext(src)[1].lower() not in EXTS:',
    '                continue',
    '            b = os.path.basename(src)',
    '            if not seg_ok(b):',
    '                continue',
    '            try:',
    '                # O_NOFOLLOW refuses a symlinked source; O_NONBLOCK stops a',
    '                # fifo parking this process on the open forever, which is',
    '                # exactly what happens without it; the fstat then refuses',
    '                # the fifo or device outright.',
    '                sfd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    '            except OSError:',
    '                continue',
    '            try:',
    '                if not stat.S_ISREG(os.fstat(sfd).st_mode):',
    '                    continue',
    '                try:',
    '                    dfd = os.open(b, os.O_WRONLY | os.O_CREAT | os.O_TRUNC',
    '                                  | os.O_NOFOLLOW, 0o644, dir_fd=fam_fd)',
    '                except OSError:',
    '                    continue  # a symlink already sitting at that name',
    '                try:',
    '                    while True:',
    '                        chunk = os.read(sfd, 1 << 20)',
    '                        if not chunk:',
    '                            break',
    '                        while chunk:',
    '                            chunk = chunk[os.write(dfd, chunk):]',
    '                finally:',
    '                    os.close(dfd)',
    '                n += 1',
    '            finally:',
    '                os.close(sfd)',
    '        if n == 0:',
    '            die("no installable font files")',
    '        fc_cache(os.readlink("/proc/self/fd/%d" % fam_fd))',
    '    finally:',
    '        closeall(fds)',
    '    sys.stdout.write("%d\\n" % n)',
    '',
    'def do_remove(argv):',
    '    home = home_dir()',
    '    root = os.path.join(home, *FONT_DIR)',
    '    prefix = root + "/"',
    '    fds = []',
    '    try:',
    '        base = os.open(home, os.O_RDONLY | os.O_DIRECTORY)',
    '        fds.append(base)',
    '        try:',
    '            fonts_fd, more = walk(base, FONT_DIR)',
    '            fds += more',
    '        except SystemExit:',
    '            return  # no user font directory at all: nothing to remove',
    '        for p in argv:',
    '            if not p.startswith(prefix):',
    '                die("refused: outside user font directory")',
    '            rel = p[len(prefix):].split("/")',
    '            if not all(seg_ok(s) for s in rel):',
    '                die("refused: bad path")',
    '            cur, sub_fds = fonts_fd, []',
    '            try:',
    '                for c in rel[:-1]:',
    '                    cur = opendir(cur, c)',
    '                    sub_fds.append(cur)',
    '                leaf = rel[-1]',
    '                try:',
    '                    st = os.stat(leaf, dir_fd=cur, follow_symlinks=False)',
    '                except OSError:',
    '                    continue',
    '                # Refuse a link outright rather than unlinking whatever it',
    '                # points at -- and unlink relative to the descriptor, so the',
    '                # directory checked is the directory acted on.',
    '                if not stat.S_ISREG(st.st_mode):',
    '                    continue',
    '                try:',
    '                    os.unlink(leaf, dir_fd=cur)',
    '                except OSError:',
    '                    continue',
    '            finally:',
    '                closeall(sub_fds)',
    '        prune(fonts_fd)',
    '        fc_cache()',
    '    finally:',
    '        closeall(fds)',
    '',
    'def prune(dir_fd):',
    '    # Drop family directories left empty by a removal. Recurses on',
    '    # descriptors, so a directory swapped for a symlink mid-walk is refused',
    '    # by O_NOFOLLOW rather than followed out of the font tree.',
    '    try:',
    '        names = os.listdir(dir_fd)',
    '    except OSError:',
    '        return',
    '    for name in names:',
    '        if not seg_ok(name):',
    '            continue',
    '        try:',
    '            st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)',
    '        except OSError:',
    '            continue',
    '        if not stat.S_ISDIR(st.st_mode):',
    '            continue',
    '        try:',
    '            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,',
    '                            dir_fd=dir_fd)',
    '        except OSError:',
    '            continue',
    '        try:',
    '            prune(child)',
    '            if not os.listdir(child):',
    '                try:',
    '                    os.rmdir(name, dir_fd=dir_fd)',
    '                except OSError:',
    '                    pass',
    '        finally:',
    '            os.close(child)',
    '',
    'def do_cleantemp(argv):',
    '    d = argv[0] if argv else ""',
    '    if not d:',
    '        return',
    '    parent, name = os.path.split(d.rstrip("/"))',
    '    # Only ever our own staging directory, and only one level down from the',
    '    # runtime dir we created it in.',
    '    if not seg_ok(name) or not name.startswith("omafont-stage-"):',
    '        return',
    '    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"',
    '    if parent != runtime.rstrip("/"):',
    '        return',
    '    try:',
    '        pfd = os.open(runtime, os.O_RDONLY | os.O_DIRECTORY)',
    '    except OSError:',
    '        return',
    '    try:',
    '        try:',
    '            dfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,',
    '                          dir_fd=pfd)',
    '        except OSError:',
    '            return',
    '        try:',
    '            # The staging directory is flat by construction -- every entry is',
    '            # written under a basename -- so entries are unlinked relative to',
    '            # its descriptor and the directory itself is then removed',
    '            # relative to the runtime descriptor. No rm -rf by pathname.',
    '            for name2 in os.listdir(dfd):',
    '                try:',
    '                    st = os.stat(name2, dir_fd=dfd, follow_symlinks=False)',
    '                    if stat.S_ISDIR(st.st_mode):',
    '                        continue',
    '                    os.unlink(name2, dir_fd=dfd)',
    '                except OSError:',
    '                    continue',
    '        finally:',
    '            os.close(dfd)',
    '        try:',
    '            os.rmdir(name, dir_fd=pfd)',
    '        except OSError:',
    '            pass',
    '    finally:',
    '        os.close(pfd)',
    '',
    '# python3 -c PROG verb a b  =>  argv[0] is "-c", so the verb is argv[1].',
    'verb = sys.argv[1] if len(sys.argv) > 1 else ""',
    'rest = sys.argv[2:]',
    'if verb == "install":',
    '    do_install(rest)',
    'elif verb == "remove":',
    '    do_remove(rest)',
    'elif verb == "cleantemp":',
    '    do_cleantemp(rest)',
    'else:',
    '    die("unknown operation")'
  ].join("\n")

  Process {
    id: installer
    stderr: StdioCollector {}
    onExited: function(code) {
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
    var args = ["/usr/bin/python3", "-c", root.fsOpsProgram, "install", root.slug(group)]
    for (var i = 0; i < faces.length; i++) args.push(faces[i].file)
    installer.command = args
    installer.running = true
  }

  // ---- Remove ------------------------------------------------------------
  // Every path is re-checked against the user font root on the other side, and
  // each component is then reopened with O_NOFOLLOW from the font-root
  // descriptor, so a bad selection in QML -- or a family directory swapped for
  // a symlink after the check -- still cannot delete anything outside the
  // tree. Empty directories are pruned afterwards so uninstalling a family
  // does not leave its folder behind.

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
    var args = ["/usr/bin/python3", "-c", root.fsOpsProgram, "remove"]
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
    // omarchy-font-set lives under $OMARCHY_PATH/bin, which is not a standard
    // prefix, so it is resolved from the environment rather than found on PATH
    // -- and rather than hardcoded, which would break a non-default install.
    monoSetter.command = [root.omarchyBin + "/omarchy-font-set", s.name]
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
    command: ["/bin/sh", "-c",
              "PATH=/usr/local/bin:/usr/bin:/bin; export PATH; "
              + "command -v zenity >/dev/null 2>&1"]
    onExited: function(code) { root.hasPicker = (code === 0) }
  }

  Process {
    id: picker
    command: ["/usr/bin/zenity", "--file-selection", "--multiple", "--separator=\n",
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
    '# The shell process inherits a PATH with user-writable directories ahead',
    '# of /usr/bin, so every bare command name here would be substitutable.',
    '# Pin it before running anything.',
    'PATH=/usr/local/bin:/usr/bin:/bin',
    'export PATH',
    '# A shell plugin runs inside the shell process, and the extract target is',
    '# $XDG_RUNTIME_DIR -- tmpfs, i.e. RAM. An unbounded extract there does not',
    '# break this panel, it takes the desktop session down.',
    '#',
    '# So the budget is enforced DURING extraction rather than measured after it.',
    '# Each entry is unpacked on its own through `head -c`, capped at whatever is',
    '# left of the shared budget, so the total that can ever reach tmpfs is bounded',
    '# by MAX_BYTES no matter what the archive\'s headers claim. A forged header can',
    '# still get past the cheap gate below; it cannot get past this.',
    'MAX_BYTES=134217728',
    'MAX_ENTRIES=4000',
    'MAX_SECONDS=120',
    'work=""',
    'found=0',
    'used=0',
    'for src in "$@"; do',
    '  case "$src" in',
    '    *.zip|*.ZIP)',
    '      # Cheap gate on the declared totals, so an obviously hostile archive',
    '      # costs nothing. Headers lie; this is an optimisation, not the defence.',
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
    '        # mktemp -d, not a $$-derived name: $$ is predictable, so the',
    '        # rm -rf/mkdir pair it needed could be raced or redirected through',
    '        # a symlink planted at that path. mktemp creates the directory',
    '        # itself, exclusively, mode 700, with a random name.',
    '        work=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/omafont-stage-XXXXXXXXXX") || exit 2',
    '        printf "TEMP %s\\n" "$work"',
    '      fi',
    '      trap \'rm -rf -- "$work" 2>/dev/null; exit 143\' TERM INT HUP',
    '      # The entry list is attacker-controlled too, so it is read bounded, and',
    '      # into a file rather than a pipe: a `while read` on the right-hand side',
    '      # of a pipe runs in a subshell, and the running total would not survive',
    '      # the loop.',
    '      names="$work/.omafont-names"',
    '      timeout 10 unzip -Z1 "$src" 2>/dev/null | head -n "$MAX_ENTRIES" > "$names" || true',
    '      deadline=$(( $(date +%s) + MAX_SECONDS ))',
    '      while IFS= read -r name; do',
    '        # Flatten to a basename, so no entry can write outside $work however',
    '        # its stored name is spelled.',
    '        base=${name##*/}',
    '        [ -n "$base" ] || continue',
    '        # unzip reads the name as a shell pattern. Rather than let one crafted',
    '        # entry name match many entries, refuse the metacharacters outright.',
    '        case "$name" in *\'*\'*|*\'?\'*|*\'[\'*|*\\\\*) continue ;; esac',
    '        ext=$(printf %s "${base##*.}" | tr \'[:upper:]\' \'[:lower:]\')',
    '        case "$ext" in ttf|otf|ttc) ;; *) continue ;; esac',
    '        # Nothing outside this set can name a file we create.',
    '        case "$base" in *[!A-Za-z0-9._\\ -]*) continue ;; esac',
    '        [ "$(date +%s)" -lt "$deadline" ] || {',
    '          rm -rf -- "$work"',
    '          echo "that archive took too long to unpack" >&2',
    '          exit 3',
    '        }',
    '        remaining=$((MAX_BYTES - used))',
    '        if [ "$remaining" -le 0 ]; then',
    '          rm -rf -- "$work"',
    '          echo "that archive expanded past the size limit" >&2',
    '          exit 3',
    '        fi',
    '        # head -c bounds the WRITE: at most the unspent budget, plus the one',
    '        # byte that proves it was exceeded, can reach tmpfs for this entry.',
    '        timeout 60 unzip -p "$src" "$name" 2>/dev/null \\',
    '          | head -c "$((remaining + 1))" > "$work/$base" || true',
    '        sz=$(wc -c < "$work/$base" 2>/dev/null) || sz=0',
    '        case "$sz" in \'\'|*[!0-9]*) sz=0 ;; esac',
    '        if [ "$sz" -eq 0 ]; then',
    '          rm -f -- "$work/$base"',
    '          continue',
    '        fi',
    '        used=$((used + sz))',
    '        if [ "$used" -gt "$MAX_BYTES" ]; then',
    '          rm -rf -- "$work"',
    '          echo "that archive expanded past the size limit" >&2',
    '          exit 3',
    '        fi',
    '      done < "$names"',
    '      rm -f -- "$names"',
    '      trap - TERM INT HUP',
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
        var cmd = ["/bin/sh", "-c", root.boundedFcScanScript, "omafont-stagescan",
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
      }
    }
  }

  // Deleting a zip we extracted. Confined to our own temp prefix, and the
  // script re-checks that rather than trusting the caller.

  function clearStage() {
    // Stop the workers FIRST. Removing the temp tree while unzip is still
    // writing into it just leaves a fresh one behind -- in RAM, since the
    // extract target is tmpfs. The prep script also traps its own signals and
    // cleans up, so this is belt and braces.
    root.picking = false
    if (stagePrep.running) stagePrep.running = false
    if (stageScan.running) stageScan.running = false
    if (root.stagedTemp) {
      Quickshell.execDetached(["/usr/bin/python3", "-c", root.fsOpsProgram,
                               "cleantemp", root.stagedTemp])
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
    var cmd = ["/bin/sh", "-c", root.stagePrepScript, "omafont-stage"]
    stagePrep.command = cmd.concat(clean)
    stagePrep.running = true
  }

  function open(payloadJson) {
    root.opened = true
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

          Text {
            textFormat: Text.PlainText
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Fonts"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
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
