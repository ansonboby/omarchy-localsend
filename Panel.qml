import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// LocalSend mini-app for the omarchy bar (plugin "anson.localsend").
//
// One entry point, dropbox pattern: a BarIconButton plus a KeyboardPanel
// popout from the same Panel root. The panel scans nearby devices through
// the headless ~/.local/bin/lsend CLI, sends files/folder/text/clipboard,
// drives the omarchy-localsend-receiver.service systemd unit (toggling
// receive mode, persisting receiver.conf), and shows recent transfers
// from history.json. Receive events stream in via `journalctl --user -f`
// on the unit — the QML never runs `lsend receive` itself.

Panel {
  id: root
  moduleName: "anson.localsend"
  ipcTarget: "anson.localsend"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits (open/close/toggle plus the receive and app verbs below).
  manageIpc: false

  // --- paths & settings ---------------------------------------------------

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/anson.localsend"
  readonly property string stateDir: home + "/.local/state/localsend-menu"
  readonly property string historyPath: stateDir + "/history.json"
  readonly property string receiverConfPath: stateDir + "/receiver.conf"
  readonly property string receiverUnit: "omarchy-localsend-receiver.service"
  readonly property string lsendBin: home + "/.local/bin/lsend"
  readonly property string openAppScript: pluginDir + "/scripts/open-app.sh"

  // Save dir may be written with a ~ in settings; resolve it here so both
  // the folder picker shortcut and receiver.conf (path must be absolute —
  // the receive wrapper strips quotes but does not expand ~) agree.
  readonly property string saveDirSetting: String(setting("saveDir", "~/Downloads") || "~/Downloads")
  readonly property string saveDir: saveDirSetting.startsWith("~") ? home + saveDirSetting.slice(1) : saveDirSetting
  readonly property bool requirePin: setting("requirePin", false) === true
  readonly property string pin: String(setting("pin", "") || "")
  readonly property int scanTimeoutMs: Math.max(2000, parseInt(setting("scanTimeoutMs", 6000), 10) || 6000)
  readonly property int historyLimit: {
    var parsed = parseInt(setting("historyLimit", 50), 10)
    return isNaN(parsed) ? 50 : Math.max(0, parsed)
  }

  // Bar icon: prefer the logo image; fall back to the configured glyph
  // (or a plain two-letter mark) if the image is absent or fails to load.
  readonly property string iconImageDefault: "/usr/share/icons/hicolor/512x512/apps/localsend.png"
  readonly property string iconImageSetting: String(setting("iconImage", iconImageDefault) || "")
  readonly property string glyphSetting: String(setting("iconGlyph", "") || "")
  property bool iconImageLoadFailed: false
  readonly property bool hasIconImage: iconImageSetting !== "" && !iconImageLoadFailed
  readonly property string barGlyph: glyphSetting !== "" ? glyphSetting : "LS"

  // --- palette ------------------------------------------------------------

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // --- state --------------------------------------------------------------

  // Devices + scan
  property var devicesModel: []
  property string scanState: "idle" // idle | scanning | done
  property string scanError: ""
  property string selectedIp: ""
  property string selectedAlias: ""
  property string lastTargetIp: ""
  property int deviceIndex: 0

  // Receiver
  property bool receiving: false
  property bool receiveBusy: false
  property bool startReceiverAfterProbe: false
  // Queued user intent (newest wins) applied as soon as the single-shot
  // ctl/probe slots free up — never swallow a toggle click.
  property int pendingReceive: -1 // -1 none, 0 set off, 1 set on
  // Set when a handoff stop should be followed by launching the GUI app.
  property bool launchAppAfterCtl: false
  property string ctlVerb: ""

  // Transfers
  property var sendQueue: []
  property var activeSend: null
  readonly property bool transferActive: activeSend !== null

  // History
  property var historyModel: []

  // Minor UI state
  property string hint: ""
  property bool flashActive: false
  property string scanOutput: ""

  // --- generic helpers ----------------------------------------------------

  function baseName(path) {
    var text = String(path || "")
    var parts = text.split("/")
    return parts[parts.length - 1] || text
  }

  function lastJsonLine(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line === "") continue
      try { return JSON.parse(line) } catch (err) { return null }
    }
    return null
  }

  function notify(title, body) {
    // argv execution: no shell passes over alias/filename text.
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash", "omarchy-notification-send", "-a", "LocalSend", String(title || ""), String(body || "")])
  }

  function runScript(script) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash", script])
  }

  function openInFileManager(path) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash", "xdg-open", path])
  }

  // --- scan ---------------------------------------------------------------

  function startScan() {
    if (scanProc.running) return
    devicesModel = []
    scanState = "scanning"
    scanError = ""
    hint = ""
    deviceIndex = 0
    scanOutput = ""
    var argv = [lsendBin, "scan", "--json", "--timeout", String(scanTimeoutMs)]
    scanProc.command = argv
    scanProc.running = true
  }

  function finishScan(exitCode) {
    var data = lastJsonLine(String(scanOutput || scanStdout.text || ""))
    var list = data && typeof data === "object" && Array.isArray(data.devices) ? data.devices : []
    var found = []
    for (var i = 0; i < list.length; i++) {
      var device = list[i] || {}
      if (typeof device !== "object") continue
      var ip = String(device.ip || device.address || device.addr || "").trim()
      if (ip === "") continue
      var alias = String(device.alias || device.name || device.device || "").trim()
      if (alias === "") alias = String(device.model || "Unnamed device")
      found.push({ ip: ip, alias: alias, model: String(device.model || "") })
    }
    // De-duplicate by IP: defensively, in case the CLI reports one device twice.
    var unique = []
    for (var j = 0; j < found.length; j++) {
      var dup = false
      for (var k = 0; k < unique.length; k++) {
        if (unique[k].ip === found[j].ip) { dup = true; break }
      }
      if (!dup) unique.push(found[j])
    }
    devicesModel = unique
    scanState = "done"
    if (exitCode !== 0 && unique.length === 0)
      scanError = "Scan failed — lsend exited with code " + exitCode

    // Selection: keep the last target when it is still around, else pick
    // the first device; keep nothing selected on an empty list.
    var next = ""
    var nextAlias = ""
    for (var m = 0; m < unique.length; m++) {
      if ((lastTargetIp !== "" && unique[m].ip === lastTargetIp) || (lastTargetIp === "" && m === 0)) {
        next = unique[m].ip
        nextAlias = unique[m].alias
        break
      }
    }
    if (next === "" && unique.length > 0) {
      next = unique[0].ip
      nextAlias = unique[0].alias
    }
    selectedIp = next
    selectedAlias = nextAlias
    lastTargetIp = next
    deviceIndex = indexForIp(next)
  }

  function indexForIp(ip) {
    var list = Array.isArray(devicesModel) ? devicesModel : []
    for (var i = 0; i < list.length; i++) {
      if (list[i].ip === ip) return i
    }
    return 0
  }

  function selectDevice(index) {
    var list = Array.isArray(devicesModel) ? devicesModel : []
    if (index < 0 || index >= list.length) return
    selectedIp = list[index].ip
    selectedAlias = list[index].alias
    deviceIndex = index
    lastTargetIp = selectedIp
    hint = ""
    saveTarget()
  }

  function saveTarget() {
    if (selectedIp === "") return
    try {
      targetFile.setText(JSON.stringify({ ip: selectedIp, alias: selectedAlias }))
    } catch (err) {}
  }

  // --- send ---------------------------------------------------------------

  function nudgeSelect() {
    hint = "Select a device first"
    flashActive = true
    flashTimer.restart()
    hintTimer.restart()
  }

  function targetPretty() {
    if (selectedAlias !== "") return selectedAlias
    if (selectedIp !== "") return selectedIp
    return "No device selected"
  }

  // Hero meta line: caps, dot separators, one summary glance.
  function heroMetaLine() {
    var lines = []
    lines.push(devicesModel.length === 1 ? "1 DEVICE" : devicesModel.length + " DEVICES")
    if (transferActive) lines.push("SENDING")
    else if (receiving) lines.push("RECEIVE ON")
    else if (scanState === "scanning") lines.push("SCANNING")
    else lines.push("RECEIVE OFF")
    var recent = historyModel.length > 0
    if (recent) lines.push(String(historyModel.length) + " RECENT")
    return lines.join("  ·  ")
  }

  // user-facing paths read best shortened to ~.
  function tildePath(p) {
    return p !== "" && p.startsWith(home) ? "~" + p.slice(home.length) : p
  }

  function pickPaths(mode) {
    if (selectedIp === "") { nudgeSelect(); return }
    if (pickProc.running) return
    pickProc.pickMode = mode
    var argv
    if (mode === "folder") {
      argv = ["bash", pluginDir + "/scripts/pick.sh", "--directory"]
    } else {
      argv = ["bash", pluginDir + "/scripts/pick.sh", "--multiple"]
    }
    pickOutput = ""
    pickProc.command = argv
    pickProc.running = true
  }

  function finishPick(exitCode) {
    var mode = pickProc.pickMode
    var data = lastJsonLine(String(pickOutput || pickStdout.text || ""))
    if (!data || typeof data !== "object") return
    if (data.ok !== true || data.cancel === true) return
    var raw = Array.isArray(data.paths) ? data.paths : []
    var clean = []
    for (var i = 0; i < raw.length; i++) {
      var path = String(raw[i] || "").trim()
      if (path !== "") clean.push(path)
    }
    if (clean.length === 0) return
    if (selectedIp === "") { nudgeSelect(); return }

    var peer = selectedAlias !== "" ? selectedAlias : selectedIp
    var name
    if (mode === "folder") {
      name = baseName(clean[0]) + "/"
    } else if (clean.length > 1) {
      name = String(clean.length) + " files"
    } else {
      name = baseName(clean[0])
    }
    queueSend({
      kind: "file",
      name: name,
      peer: peer,
      count: clean.length,
      argv: [lsendBin, "send", selectedIp].concat(clean).concat(["--json", "--no-scan"])
    })
  }

  function sendMessage() {
    var text = String(messageField.text || "").trim()
    if (text === "") return
    if (selectedIp === "") { nudgeSelect(); return }
    queueSend({
      kind: "message",
      name: "Message · " + (text.length > 24 ? text.slice(0, 24) + "…" : text),
      peer: selectedAlias !== "" ? selectedAlias : selectedIp,
      argv: [lsendBin, "send", selectedIp, "--message", text, "--json", "--no-scan"]
    })
    messageField.text = ""
  }

  function sendClipboard() {
    if (selectedIp === "") { nudgeSelect(); return }
    queueSend({
      kind: "clipboard",
      name: "Clipboard",
      peer: selectedAlias !== "" ? selectedAlias : selectedIp,
      argv: [lsendBin, "send", selectedIp, "--clipboard", "--json", "--no-scan"]
    })
  }

  function queueSend(job) {
    job.state = "queued"
    var queue = Array.isArray(sendQueue) ? sendQueue.slice() : []
    queue.push(job)
    sendQueue = queue
    pumpSend()
  }

  function pumpSend() {
    if (activeSend !== null) return
    var queue = Array.isArray(sendQueue) ? sendQueue.slice() : []
    if (queue.length === 0) return
    var job = queue.shift()
    job.state = "running"
    sendQueue = queue
    activeSend = job
    sendOutput = ""
    sendProc.command = job.argv.slice()
    sendProc.running = true
  }

  function finalizeSend(exitCode) {
    if (activeSend === null) return
    var job = activeSend
    var ok = exitCode === 0
    // Defensive parse: exit code 0 + JSON ok:true is a success; explicit
    // ok:false or any per-file "failed" status marks the transfer failed.
    // There is no live progress in --json mode, so we judge on the final line.
    var data = lastJsonLine(String(sendOutput || sendStdout.text || ""))
    if (data && typeof data === "object") {
      if (data.ok === false) ok = false
      else if (data.ok === true) ok = true
      if (Array.isArray(data.files)) {
        for (var i = 0; i < data.files.length; i++) {
          var entry = data.files[i] || {}
          if (typeof entry !== "object") continue
          if (String(entry.status || "") === "failed") ok = false
        }
      }
    }
    job.ok = ok
    job.state = ok ? "done" : "failed"
    addHistory("out", job.name, job.peer, ok, job.count)
    if (ok) {
      notify("LocalSend: sent", job.name + " → " + job.peer)
    } else {
      notify("LocalSend: send failed", job.name + " could not reach " + job.peer)
    }
    activeSend = null
    pumpSend()
  }

  // --- receiving ----------------------------------------------------------

  function writeReceiverConf() {
    var lines = ["dir=" + Util.shellQuote(saveDir)]
    // The conf format can't round-trip an embedded quote — enforce a numeric
    // PIN the schema already advertises ("Numeric PIN").
    var cleanPin = requirePin ? pin.replace(/[^0-9]/g, "") : ""
    if (cleanPin !== "") lines.push("pin=" + cleanPin)
    try {
      receiverConfFile.setText(lines.join("\n") + "\n")
    } catch (err) {}
  }

  function toggleReceive(on) {
    // A click can land while the previous systemctl run has not exited yet
    // (the 5 s is-active poll shares the slot). Never swallow it: keep the
    // newest intent and apply it the moment a slot frees.
    if (receiveBusy || ctlProc.running || appProbe.running) {
      pendingReceive = on ? 1 : 0
      hint = "Applying receive change…"
      hintTimer.restart()
      return false
    }
    pendingReceive = -1
    receiveBusy = true
    if (on) {
      writeReceiverConf()
      startReceiverAfterProbe = true
      // A running GUI LocalSend app owns the same port; close it first.
      appProbe.running = true
    } else {
      runCtl("stop")
    }
    return true
  }

  function flushPendingToggle() {
    if (pendingReceive < 0) return
    var want = pendingReceive === 1
    if (toggleReceive(want)) pendingReceive = -1
  }

  // Single entry point for every "open the GUI app" path: footer button,
  // right-click on the bar icon, and the o key. The app and the receiver
  // daemon bind the same port, so an active daemon hands the port over
  // before the app starts — otherwise the app lands on OS error 98
  // ("address already in use") and shows itself offline.
  function openFullApp() {
    if (receiving) {
      launchAppAfterCtl = true
      runCtl("stop")
      return
    }
    runScript(openAppScript)
  }

  function runCtl(verb) {
    if (ctlProc.running) return
    var argv = []
    if (verb === "start") argv = ["systemctl", "--user", "restart", receiverUnit]
    else if (verb === "stop") argv = ["systemctl", "--user", "stop", receiverUnit]
    else if (verb === "check") argv = ["systemctl", "--user", "is-active", receiverUnit]
    else return
    ctlVerb = verb
    ctlProc.command = argv
    ctlProc.running = true
  }

  function refreshReceiver() {
    if (!receiveBusy) runCtl("check")
  }

  // --- receive events (journal follow) ------------------------------------

  function extractString(obj, keys) {
    for (var i = 0; i < keys.length; i++) {
      var value = obj[keys[i]]
      if (typeof value === "string" && value !== "") return value
    }
    // One level of nesting / one first element, defensively.
    for (var j = 0; j < keys.length; j++) {
      var inner = obj[keys[j]]
      if (inner && typeof inner === "object" && !Array.isArray(inner)) {
        var nested = extractString(inner, keys)
        if (nested !== "") return nested
      }
      if (Array.isArray(inner) && inner.length > 0 && inner[0] && typeof inner[0] === "object") {
        var first = extractString(inner[0], keys)
        if (first !== "") return first
      }
    }
    return ""
  }

  function receivePeerOf(obj) {
    var from = obj.from
    if (typeof from === "string" && from !== "") return from
    if (from && typeof from === "object") {
      var alias = extractString(from, ["alias", "name", "ip"])
      if (alias !== "") return alias
    }
    return extractString(obj, ["sender", "peer", "device"])
  }

  function receiveNameOf(obj) {
    var name = extractString(obj, ["name", "filename", "file", "path"])
    if (name !== "") return baseName(name)
    return String(JSON.stringify(obj)).slice(0, 90)
  }

  function handleReceiveLine(line) {
    var text = String(line || "").trim()
    if (text === "" || text.charAt(0) !== "{") return
    var obj
    try { obj = JSON.parse(text) } catch (err) { return }
    if (!obj || typeof obj !== "object") return
    var kind = String(obj.event || obj.type || obj.kind || obj.command || "").toLowerCase()
    var ok = obj.ok !== false
    var peer = receivePeerOf(obj)

    var failure = !ok || kind.indexOf("fail") >= 0 || kind.indexOf("error") >= 0 ||
      kind.indexOf("declin") >= 0 || kind.indexOf("cancel") >= 0
    if (failure) {
      addHistory("in", receiveNameOf(obj), peer, false)
      notify("LocalSend: receive failed", receiveNameOf(obj))
      return
    }

    var complete = kind.indexOf("complete") >= 0
    var saved = kind.indexOf("saved") >= 0 || kind.indexOf("finish") >= 0
    if (!complete && !saved) return
    var name = receiveNameOf(obj)
    if (complete) {
      addHistory("in", name, peer, true)
      notify("LocalSend: received", name + " from " + (peer !== "" ? peer : "a nearby device"))
    }
  }

  // --- history ------------------------------------------------------------

  function addHistory(dir, name, peer, ok, count) {
    var entry = {
      dir: String(dir || "out"),
      name: String(name || ""),
      peer: String(peer || ""),
      at: Date.now(),
      ok: ok === true
    }
    if (count !== undefined) entry.count = count
    var list = Array.isArray(historyModel) ? historyModel.slice() : []
    list.unshift(entry)
    if (list.length > historyLimit) list = list.slice(0, historyLimit)
    historyModel = list
    persistHistory()
  }

  function clearHistory() {
    historyModel = []
    persistHistory()
  }

  function persistHistory() {
    try {
      historyFile.setText(JSON.stringify(historyModel, null, 2))
    } catch (err) {}
  }

  function loadHistory(raw) {
    var out = []
    var data = null
    try { data = JSON.parse(String(raw || "[]")) } catch (err) { data = null }
    if (Array.isArray(data)) {
      for (var i = 0; i < data.length; i++) {
        var entry = data[i] || {}
        if (typeof entry !== "object" || entry === null) continue
        out.push({
          dir: String(entry.dir || "out") === "in" ? "in" : "out",
          name: String(entry.name || ""),
          peer: String(entry.peer || ""),
          at: Number(entry.at || 0),
          ok: entry.ok !== false
        })
      }
    }
    historyModel = out
  }

  // --- keyboard cursor (device list) --------------------------------------

  function moveCursor(dy) {
    var len = Array.isArray(devicesModel) ? devicesModel.length : 0
    if (len === 0) return
    deviceIndex = Math.max(0, Math.min(len - 1, deviceIndex + dy))
  }

  function activateCursor() {
    if (Array.isArray(devicesModel) && devicesModel.length > 0) selectDevice(deviceIndex)
  }

  // --- popup lifecycle ----------------------------------------------------

  onOpenedChanged: {
    if (!opened) return
    panelFlick.contentY = 0
    refreshReceiver()
    if (scanState !== "scanning" && Array.isArray(devicesModel) && devicesModel.length === 0) startScan()
  }

  // --- bar root sizing ----------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- state dir bootstrap ------------------------------------------------

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    running: true
    onExited: {
      // The first read collapses if the directory did not exist yet.
      targetFile.reload()
      historyFile.reload()
    }
  }

  // --- persisted files ----------------------------------------------------

  FileView {
    id: targetFile
    path: root.stateDir + "/target.json"
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: {
      var data = null
      try { data = JSON.parse(text()) } catch (err) { data = null }
      if (data && typeof data === "object") {
        root.lastTargetIp = String(data.ip || "")
        if (root.selectedIp === "" && root.lastTargetIp !== "") {
          root.selectedIp = root.lastTargetIp
          root.selectedAlias = String(data.alias || "")
        }
      }
    }
    onLoadFailed: root.lastTargetIp = ""
  }

  FileView {
    id: historyFile
    path: root.historyPath
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onLoaded: root.loadHistory(text())
    onLoadFailed: root.loadHistory("")
    onFileChanged: reload()
  }

  FileView {
    id: receiverConfFile
    path: root.receiverConfPath
    atomicWrites: true
    watchChanges: false
    printErrors: false
  }

  // --- processes ----------------------------------------------------------

  Process {
    id: scanProc
    running: false
    command: []
    stdout: StdioCollector {
      id: scanStdout
      waitForEnd: true
      onStreamFinished: root.scanOutput = text
    }
    onExited: function(exitCode) {
      root.finishScan(exitCode)
    }
  }

  Process {
    id: pickProc
    running: false
    command: []
    property string pickMode: "files"
    stdout: StdioCollector {
      id: pickStdout
      waitForEnd: true
      onStreamFinished: root.pickOutput = text
    }
    onExited: function(exitCode) {
      root.finishPick(exitCode)
    }
  }

  property string pickOutput: ""

  Process {
    id: sendProc
    running: false
    command: []
    stdout: StdioCollector {
      id: sendStdout
      waitForEnd: true
      onStreamFinished: root.sendOutput = text
    }
    onExited: function(exitCode) {
      root.finalizeSend(exitCode)
    }
  }

  property string sendOutput: ""

  // Long-running follower on the receiver unit's journal. lsend receive
  // (started by the systemd wrapper) logs NDJSON events; the QML never
  // runs receive itself. Restarts itself if journalctl ever exits.
  Process {
    id: journalProc
    command: ["journalctl", "--user", "-f", "-n", "0", "-u", root.receiverUnit, "--output=cat"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        root.handleReceiveLine(line)
      }
    }
    onExited: journalRestartTimer.restart()
  }

  Timer {
    id: journalRestartTimer
    interval: 5000
    onTriggered: if (!journalProc.running) journalProc.running = true
  }

  // IPC: standard panel verbs plus receive/app verbs so the mode is
  // keybind- and script-reachable without clicking.
  IpcHandler {
    target: "anson.localsend"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function receiveOn() { root.toggleReceive(true) }
    function receiveOff() { root.toggleReceive(false) }
    function openApp() { root.openFullApp() }
  }

  // systemctl single-slot controller: start / stop / is-active.
  Process {
    id: ctlProc
    running: false
    command: []
    onExited: function(exitCode) {
      var verb = root.ctlVerb
      root.ctlVerb = ""
      root.receiveBusy = false
      if (verb === "check") {
        root.receiving = exitCode === 0
      } else if (verb === "start") {
        root.receiving = exitCode === 0
        if (exitCode === 0)
          root.notify("LocalSend: receive mode on", "Saving to " + root.saveDir)
        else
          root.notify("LocalSend: receiver failed", "systemctl --user restart " + root.receiverUnit + " exited with code " + exitCode)
      } else if (verb === "stop") {
        root.receiving = false
        if (root.launchAppAfterCtl) {
          // Port handoff: daemon stopped because the user asked for the GUI app.
          root.launchAppAfterCtl = false
          root.notify("LocalSend: receive mode off", "Port handed to the GUI app — it will find nothing in use now")
          Qt.callLater(root.runScript, root.openAppScript)
        } else {
          root.notify("LocalSend: receive mode off", "Receiver stopped")
        }
      }
      // No self-rescheduling here: the 5 s refreshTimer is the steady-state
      // poll, and a Qt.callLater refresh used to near-saturate the single
      // ctl slot with checks — swallowing every real start/stop click.
      if (root.pendingReceive >= 0)
        Qt.callLater(root.flushPendingToggle)
    }
  }

  // Probe: is the GUI LocalSend app running? If yes, close it (same port)
  // before starting the receiver, and tell the user why.
  Process {
    id: appProbe
    running: false
    command: ["bash", "-c",
      "set +e\n" +
      "killed=0\n" +
      "if pgrep -x localsend >/dev/null 2>&1; then pkill -x localsend; killed=1; fi\n" +
      "if pgrep -x localsend_app >/dev/null 2>&1; then pkill -x localsend_app; killed=1; fi\n" +
      "if [ \"$killed\" = \"1\" ]; then sleep 0.6; echo killed; fi\n" +
      "true\n"]
    onExited: {
      try {
        // StdioCollector.text is read-only in Quickshell 0.3 — never assign
        // to it. A prior run's stray "killed" would at worst re-notify.
        var said = String(appProbeStdout.text || "").trim()
        if (said === "killed")
          root.notify("LocalSend app closed", "The GUI app was using the receive port.")
        if (root.startReceiverAfterProbe) {
          root.startReceiverAfterProbe = false
          root.runCtl("start")
        } else {
          root.receiveBusy = false
          root.flushPendingToggle()
        }
      } catch (err) {
        console.log("localsend: appProbe handler error: " + err)
        root.receiveBusy = false
      }
    }
    stdout: StdioCollector {
      id: appProbeStdout
      waitForEnd: true
    }
  }

  // Receiver status poll — light systemctl is-active every 5 s, always on.
  Timer {
    id: refreshTimer
    interval: 5000
    repeat: true
    running: true
    onTriggered: root.refreshReceiver()
  }

  Timer {
    id: flashTimer
    interval: 1400
    onTriggered: root.flashActive = false
    onRunningChanged: if (!running) root.flashActive = false
  }

  Timer {
    id: hintTimer
    interval: 5000
    onTriggered: root.hint = ""
    onRunningChanged: if (!running) root.hint = ""
  }

  // --- bar button ---------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Glyph is only rendered when the logo is unusable (BarIconButton
    // prefers the iconComponent when it is non-null).
    text: root.hasIconImage ? "" : root.barGlyph
    iconComponent: root.hasIconImage ? imageComponent : null
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openFullApp()
      else root.toggle()
    }
  }

  // Inline resource: the logo image inside the bar icon slot.
  Component {
    id: imageComponent

    Item {
      Image {
        anchors.centerIn: parent
        width: Style.space(15)
        height: Style.space(15)
        source: Util.fileUrl(root.iconImageSetting)
        mipmap: true
        fillMode: Image.PreserveAspectFit
        // Design language: state lives in glyph intensity, never in a dot —
        // bright while receiving or sending, dim otherwise (dropbox pattern).
        opacity: root.receiving || root.transferActive ? 1.0 : 0.6
        Behavior on opacity { NumberAnimation { duration: 200 } }
        onStatusChanged: if (status === Image.Error || status === Image.Null) root.iconImageLoadFailed = true
      }
    }
  }

  // --- popup panel --------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The message field needs the keys itself while focused.
      blocked: messageField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.startScan()
        else if (t === "o" || t === "O") root.openFullApp()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.space(10)

          // --- header -------------------------------------------------------
          // PanelHero: tinted logo, a title that names the state in plain
          // words, a caps meta line with dot separators, and one trailing
          // control (refresh) per the design language.

          PanelHero {
            id: hero
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: root.transferActive
              ? "Sending to " + root.activeSend.peer
              : (root.receiving ? "Receiving is on" : "LocalSend")
            meta: root.heroMetaLine()
            detail: root.selectedIp === ""
              ? root.tildePath(root.saveDir)
              : "to " + root.selectedAlias
            iconOpacity: root.receiving || root.transferActive ? 1.0 : 0.85
            iconComponent: Component {
              Image {
                width: Style.font.display
                height: Style.font.display
                visible: root.hasIconImage
                source: Util.fileUrl(root.iconImageSetting)
                mipmap: true
                fillMode: Image.PreserveAspectFit
                onStatusChanged: if (status === Image.Error || status === Image.Null) root.iconImageLoadFailed = true
                Text {
                  anchors.centerIn: parent
                  visible: !root.hasIconImage
                  textFormat: Text.PlainText
                  text: "󰒊"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Re-scan devices"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !scanProc.running
                onClicked: root.startScan()
              }
            }
          }

          // Devices section highlight/flash feedback target.
          Text {
            visible: root.hint !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.hint
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // --- devices ------------------------------------------------------

          PanelSectionHeader {
            id: devicesHeader
            text: root.flashActive ? "PICK A DEVICE — THEN SEND" : "DEVICES ON THE NETWORK"
            foreground: root.flashActive ? root.urgent : root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.scanState === "scanning" && root.devicesModel.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "Scanning devices on the network…"
            color: root.dim
            font.italic: true
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            visible: root.scanState === "done" && root.devicesModel.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: root.scanError !== "" ? root.scanError : "No nearby devices found — check that LocalSend is running on the other device."
            color: root.scanError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            id: deviceList
            visible: root.devicesModel.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.devicesModel

              DeviceRow { }
            }
          }

          Button {
            visible: root.scanState !== "scanning"
            width: parent.width
            text: root.devicesModel.length > 0 ? "Re-scan" : "Re-scan for devices"
            iconText: "󰑐"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !scanProc.running
            onClicked: root.startScan()
          }

          PanelSeparator {}

          // --- send ---------------------------------------------------------

          PanelSectionHeader {
            text: "SEND TO " + root.targetPretty().toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            // Target chip: shows the current send target, click to re-scan.
            // Hidden until a device is chosen — the empty state is loud
            // enough in the section header; duplication would be noise.
            CursorSurface {
              id: targetChip
              visible: root.selectedIp !== ""
              width: parent.width
              implicitHeight: Style.space(34)
              foreground: root.foreground

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Send to"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: chipLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.space(64)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.targetPretty()
                color: root.selectedIp === "" ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: root.selectedIp !== ""
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: targetChip.hasCursor = true
                onExited: targetChip.hasCursor = false
                onClicked: root.startScan()
              }
            }

            Button {
              width: parent.width
              text: "Send files…"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.pickPaths("files")
            }

            Button {
              width: parent.width
              text: "Send a folder…"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.pickPaths("folder")
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: messageField
                width: parent.width - sendMsgButton.implicitWidth - parent.spacing
                placeholderText: "Type a message…"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onAccepted: root.sendMessage()
              }

              Button {
                id: sendMsgButton
                text: "Send"
                iconText: "󰒊"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.sendMessage()
              }
            }

            Button {
              width: parent.width
              text: "Send clipboard"
              iconText: "󰆏"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.sendClipboard()
            }
          }

          // --- receiving ----------------------------------------------------

          PanelSectionHeader {
            text: "RECEIVE MODE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Toggle {
            width: parent.width
            checked: root.receiving
            label: "Receive mode"
            description: root.receiveBusy
              ? "Applying change…"
              : (root.receiving
                ? "On · files land in " + root.tildePath(root.saveDir) + (root.requirePin && root.pin !== "" ? " · PIN required" : "") + " · opening the GUI app pauses this"
                : "Off · your phone can't send yet. The app and this daemon trade one port — both never run together")
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.toggleReceive(!root.receiving)
          }

          Button {
            width: parent.width
            text: "Open receiver folder"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openInFileManager(root.saveDir)
          }

          // --- recent transfers ---------------------------------------------

          PanelSeparator {}

          PanelSectionHeader {
            id: recentHeader
            text: "RECENT TRANSFERS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Button {
            visible: root.historyModel.length > 0
            anchors.right: parent.right
            text: "Clear"
            foreground: root.dim
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.clearHistory()
          }

          Text {
            visible: root.historyModel.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "No transfers yet"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: recentList
            visible: root.historyModel.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.historyModel.length > 6 ? root.historyModel.slice(0, 6) : root.historyModel

              HistoryRow { }
            }
          }

          // --- footer -------------------------------------------------------

          Button {
            width: parent.width
            text: root.receiving ? "Open full app · pauses receive first" : "Open full LocalSend app"
            iconText: "󰏌"
            tooltipText: root.receiving ? "The app needs the receive port — the daemon stops, then the app opens" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openFullApp()
          }

          // Keyboard footer: muted caption naming the keys the panel honors.
          PanelSeparator {}

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "esc close  ·  enter send message  ·  o open app"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Runs the headless lsend CLI — the full LocalSend app stays free for everything else."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // --- components ---------------------------------------------------------

  component DeviceRow: CursorSurface {
    id: deviceRow
    required property var modelData
    required property int index

    readonly property bool chosen: root.selectedIp !== "" && root.selectedIp === deviceRow.modelData.ip
    readonly property string modelLabel: String(deviceRow.modelData.model || "")

    width: deviceList.width
    implicitHeight: deviceContent.implicitHeight + Style.space(12)
    hasCursor: root.deviceIndex === deviceRow.index
    foreground: root.foreground

    Rectangle {
      id: deviceDot
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(9)
      height: Style.space(9)
      radius: width / 2
      color: deviceRow.chosen ? root.accent : "transparent"
      border.width: 1
      border.color: deviceRow.chosen ? root.accent : root.dim
    }

    Column {
      id: deviceContent
      anchors.left: deviceDot.right
      anchors.leftMargin: Style.space(8)
      anchors.right: deviceIp.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: deviceRow.modelData.alias
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: deviceRow.chosen
        elide: Text.ElideRight
      }

      Text {
        visible: deviceRow.modelLabel !== "" && deviceRow.modelLabel !== deviceRow.modelData.alias
        width: parent.width
        textFormat: Text.PlainText
        text: deviceRow.modelLabel
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      id: deviceIp
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: deviceRow.modelData.ip
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.deviceIndex = deviceRow.index
        root.hint = ""
      }
      onClicked: root.selectDevice(deviceRow.index)
    }
  }

  component HistoryRow: CursorSurface {
    id: historyRow
    required property var modelData
    required property int index

    readonly property bool incoming: String(modelData.dir) === "in"
    readonly property bool ok: modelData.ok !== false

    width: recentList.width
    implicitHeight: Math.max(directionGlyph.implicitHeight, historyContent.implicitHeight, historyTime.implicitHeight) + Style.space(6)
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: historyRow.hasCursor = true
      onExited: historyRow.hasCursor = false
    }

    Text {
      id: directionGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: historyRow.incoming ? "󰅢" : "󰅧"
      color: historyRow.ok ? root.accent : root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: historyContent
      anchors.left: directionGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: historyTime.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: String(historyRow.modelData.name || "Transfer")
        color: historyRow.ok ? root.foreground : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: (historyRow.incoming ? "from " : "to ") + String(historyRow.modelData.peer || "unknown") +
          (historyRow.ok ? "" : " · failed")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      id: historyTime
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: ageShort(historyRow.modelData.at)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  function ageShort(at) {
    var ms = Number(at) || 0
    if (ms <= 0) return ""
    var minutes = Math.floor(Math.max(0, Date.now() - ms) / 60000)
    if (minutes < 1) return "now"
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h"
    return Math.floor(hours / 24) + "d"
  }
}
