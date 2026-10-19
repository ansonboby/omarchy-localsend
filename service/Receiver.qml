import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string sourceDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string controllerPath: sourceDir === "" ? "" : sourceDir + "/bin/localsend-controller"

  property bool ready: false
  property string phase: "starting"
  property string lastError: ""
  property string actionStatus: ""
  property var daemon: ({})
  property var devices: []
  property var incoming: null
  property var transfers: []
  property string payloadKind: ""
  property var selectedPaths: []
  property string payloadLabel: ""
  // Finished transfers mirrored from snapshots and persisted to disk, so
  // history survives daemon and shell restarts.
  property var history: []

  // --- launch settings ------------------------------------------------------
  // Settings live inline in ~/.config/omarchy/shell.json under this plugin's
  // entry (plugins[] or bar.layout item). Read directly because service-kind
  // plugins get no runtime settings injection; key names mirror the manifest
  // schema: alias, destination.
  readonly property string home: Quickshell.env("HOME")
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string statePath: home + "/.local/state/omarchy/localsend-history.json"
  readonly property string aliasTxtPath: home + "/.config/lsend/alias.txt"
  property var pluginSettings: ({})
  property string aliasTxtAlias: ""
  readonly property string settingsAlias: String(pluginSettings.alias || "").trim()
  readonly property string resolvedAlias: settingsAlias !== "" ? settingsAlias : aliasTxtAlias
  readonly property string settingsDestinationRaw: String(pluginSettings.destination || "").trim()
  readonly property string resolvedDestination: settingsDestinationRaw.startsWith("~")
    ? home + settingsDestinationRaw.slice(1)
    : settingsDestinationRaw
  property string _launchSignature: ""

  function launchSignature() {
    return String(resolvedAlias) + "|" + String(resolvedDestination)
  }

  readonly property bool choosing: chooserProcess.running
  readonly property bool busy: choosing || rpcProcess.running
  readonly property int onlineDeviceCount: {
    var count = 0
    for (var i = 0; i < devices.length; i++) if (devices[i] && devices[i].online === true) count++
    return count
  }
  readonly property bool hasActiveTransfer: {
    for (var i = 0; i < transfers.length; i++) {
      var state = String(transfers[i] && transfers[i].state || "")
      if (state === "preparing" || state === "transferring" || state === "cancelling") return true
    }
    return false
  }

  property bool _intentionalStop: false
  property bool _restartRequested: false
  property int _restartAttempt: 0
  property var _rpcQueue: []
  property var _currentRpc: null
  property string _rpcOutput: ""
  property string _rpcError: ""
  property bool _rpcTimedOut: false
  property bool _snapshotQueued: false
  property int _snapshotFailures: 0
  property string _chooserMode: ""
  property string _chooserOutput: ""
  property string _chooserError: ""
  property var _notifiedRequests: ({})

  function concise(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 180 ? value.substring(0, 177) + "..." : value
  }

  function safeRemote(text) {
    return String(text || "Unknown device")
      .replace(/[\u0000-\u001f\u007f]/g, " ")
      .replace(/[<>&]/g, "")
      .replace(/\s+/g, " ")
      .trim()
      .substring(0, 120)
  }

  function formatBytes(value) {
    var bytes = Number(value || 0)
    if (!isFinite(bytes) || bytes < 0) bytes = 0
    var units = ["B", "KB", "MB", "GB", "TB"]
    var index = 0
    while (bytes >= 1024 && index < units.length - 1) {
      bytes /= 1024
      index++
    }
    var precision = index === 0 ? 0 : (bytes >= 10 ? 1 : 2)
    return bytes.toFixed(precision) + " " + units[index]
  }

  function baseName(path) {
    var parts = String(path || "").split("/")
    return parts.length > 0 ? parts[parts.length - 1] : String(path || "")
  }

  function startDaemon() {
    if (controllerPath === "" || daemonProcess.running) return
    _intentionalStop = false
    ready = false
    phase = "starting"
    var args = ["setpriv", "--pdeathsig", "TERM", controllerPath, "daemon"]
    if (resolvedAlias !== "") args.push("--alias", resolvedAlias)
    if (resolvedDestination !== "") args.push("--destination", resolvedDestination)
    _launchSignature = launchSignature()
    daemonProcess.command = args
    daemonProcess.running = true
  }

  function scheduleRestart(immediate) {
    if (_intentionalStop || controllerPath === "") return
    var delay = immediate === true ? 200 : Math.min(30000, 1000 * Math.pow(2, Math.min(_restartAttempt, 5)))
    _restartAttempt++
    restartTimer.interval = delay
    restartTimer.restart()
  }

  function restartDaemon() {
    _restartRequested = true
    _intentionalStop = false
    ready = false
    phase = "restarting"
    _rpcQueue = []
    _snapshotQueued = false
    if (rpcProcess.running) rpcProcess.running = false
    if (daemonProcess.running) daemonProcess.running = false
    else scheduleRestart(true)
  }

  function handleDaemonLine(line) {
    var parsed = null
    try {
      parsed = JSON.parse(String(line || ""))
    } catch (error) {
      lastError = concise(line)
      return
    }
    if (parsed && parsed.event === "ready" && parsed.ok === true) {
      ready = true
      phase = "running"
      lastError = ""
      _restartAttempt = 0
      startupTimeout.stop()
      queueSnapshot()
      return
    }
    if (parsed && parsed.ok === false && parsed.error) {
      lastError = concise(parsed.error.message || "LocalSend controller failed")
    }
  }

  function queueRpc(kind, args, successMessage, clearPayload) {
    if (!ready) {
      if (kind !== "snapshot") {
        lastError = "LocalSend receiver is not ready"
        actionStatusTimer.restart()
      }
      return
    }
    if (kind === "snapshot") {
      if (_snapshotQueued || (_currentRpc && _currentRpc.kind === "snapshot")) return
      _snapshotQueued = true
    }
    var queue = _rpcQueue.slice()
    queue.push({
      kind: kind,
      args: args,
      successMessage: successMessage || "",
      clearPayload: clearPayload === true
    })
    _rpcQueue = queue
    runNextRpc()
  }

  function queueSnapshot() {
    queueRpc("snapshot", ["snapshot"], "", false)
  }

  function runNextRpc() {
    if (rpcProcess.running || _currentRpc || _rpcQueue.length === 0 || controllerPath === "") return
    var queue = _rpcQueue.slice()
    _currentRpc = queue.shift()
    _rpcQueue = queue
    _rpcOutput = ""
    _rpcError = ""
    _rpcTimedOut = false
    rpcProcess.command = [controllerPath].concat(_currentRpc.args)
    rpcProcess.running = true
    rpcTimeout.restart()
  }

  function finishRpc(exitCode) {
    rpcTimeout.stop()
    var current = _currentRpc
    _currentRpc = null
    if (!current) {
      runNextRpc()
      return
    }
    if (current.kind === "snapshot") _snapshotQueued = false

    var raw = String(_rpcOutput || rpcStdout.text || "").trim()
    var response = null
    try {
      response = raw === "" ? null : JSON.parse(raw)
    } catch (error) {
      response = null
    }

    if (_rpcTimedOut || !response || response.ok !== true) {
      var message = _rpcTimedOut
        ? "Controller request timed out"
        : (response && response.error ? String(response.error.message || "Controller request failed") : concise(_rpcError || raw || "Controller request failed"))
      if (current.kind === "snapshot") {
        _snapshotFailures++
        if (_snapshotFailures >= 3 && daemonProcess.running) restartDaemon()
      } else {
        lastError = concise(message)
        actionStatus = ""
        actionStatusTimer.restart()
      }
    } else if (current.kind === "snapshot") {
      _snapshotFailures = 0
      applySnapshot(response.result)
    } else {
      if (current.clearPayload) clearPayload()
      lastError = ""
      actionStatus = current.successMessage
      if (actionStatus !== "") actionStatusTimer.restart()
      queueSnapshot()
    }
    runNextRpc()
  }

  function applySnapshot(snapshot) {
    if (!snapshot || !snapshot.daemon || !(snapshot.devices instanceof Array) || !(snapshot.transfers instanceof Array)) {
      lastError = "Controller returned an invalid snapshot"
      return
    }
    var previousRequest = incoming && incoming.id ? String(incoming.id) : ""
    daemon = snapshot.daemon
    devices = snapshot.devices
    incoming = snapshot.incoming || null
    transfers = snapshot.transfers
    ready = String(snapshot.daemon.status || "") === "running"
    phase = ready ? "running" : String(snapshot.daemon.status || "unavailable")
    if (snapshot.error && snapshot.error.message) lastError = concise(snapshot.error.message)
    rememberFinished(snapshot.transfers)
    if (incoming && incoming.id && String(incoming.id) !== previousRequest) notifyIncoming(incoming)
  }

  function rememberFinished(list) {
    if (!Array.isArray(list)) return
    var current = Array.isArray(history) ? history.slice() : []
    for (var i = 0; i < list.length; i++) {
      var transfer = list[i]
      if (!transfer || !transfer.id) continue
      var state = String(transfer.state || "")
      if (state !== "completed" && state !== "declined" && state !== "cancelled" && state !== "failed") continue
      var files = transfer.files instanceof Array ? transfer.files : []
      var entry = {
        id: String(transfer.id),
        direction: String(transfer.direction || "") === "incoming" ? "in" : "out",
        state: state,
        name: files.length === 1
          ? String(files[0].name || "item")
          : String(transfer.fileCount || files.length || 1) + " items",
        peer: transfer.peer && transfer.peer.alias ? String(transfer.peer.alias) : "",
        bytes: Number(transfer.totalBytes || 0),
        at: Number(transfer.finishedAt && Date.parse(transfer.finishedAt)
          ? Date.parse(transfer.finishedAt)
          : (transfer.updatedAt && Date.parse(transfer.updatedAt) ? Date.parse(transfer.updatedAt) : Date.now())),
        ok: state === "completed"
      }
      var replaced = false
      for (var j = 0; j < current.length; j++) {
        if (current[j].id !== entry.id) continue
        if (current[j].state === entry.state) { replaced = true; break }
        current.splice(j, 1)
        break
      }
      if (replaced) continue
      current.unshift(entry)
    }
    if (current.length > 24) current = current.slice(0, 24)
    if (JSON.stringify(current) !== JSON.stringify(history)) {
      history = current
      persistHistory()
    }
  }

  function persistHistory() {
    try {
      historyFile.setText(JSON.stringify(history, null, 2))
    } catch (error) {}
  }

  function loadHistory(raw) {
    var data = null
    try { data = JSON.parse(String(raw || "[]")) } catch (error) { data = null }
    var out = []
    if (Array.isArray(data)) {
      for (var i = 0; i < data.length && i < 24; i++) {
        var entry = data[i]
        if (!entry || !entry.id || !entry.name) continue
        out.push(entry)
      }
    }
    history = out
  }

  function clearHistory() {
    history = []
    persistHistory()
  }

  function loadShellConfig(raw) {
    var config = null
    try { config = JSON.parse(String(raw || "{}")) } catch (error) { config = null }
    var moduleId = (manifest && manifest.id) ? String(manifest.id) : ""
    var entries = []
    if (config && Array.isArray(config.plugins)) entries = entries.concat(config.plugins)
    var layout = config && config.bar && config.bar.layout ? config.bar.layout : null
    if (layout) {
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length; s++) {
        var list = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
        entries = entries.concat(list)
      }
    }
    var entry = null
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] && String(entries[i].id || "") === moduleId) { entry = entries[i]; break }
    }
    var previousAlias = String(pluginSettings.alias || "")
    var previousDestination = String(pluginSettings.destination || "")
    var next = ({})
    if (entry) {
      for (var key in entry) if (key !== "id") next[key] = entry[key]
    }
    pluginSettings = next

    // Relaunch the daemon only when the derived flags actually changed; the
    // next natural start picks new settings for free.
    var aliasChanged = String(pluginSettings.alias || "") !== previousAlias
    var destinationChanged = String(pluginSettings.destination || "") !== previousDestination
    if ((aliasChanged || destinationChanged) && daemonProcess.running &&
        _launchSignature !== "" && launchSignature() !== _launchSignature)
      restartDaemon()
  }

  function notifyIncoming(request) {
    var id = String(request.id || "")
    if (id === "" || _notifiedRequests[id]) return
    var next = ({})
    for (var key in _notifiedRequests) next[key] = _notifiedRequests[key]
    next[id] = true
    _notifiedRequests = next
    var sender = safeRemote(request.sender && request.sender.alias)
    var count = request.files instanceof Array ? request.files.length : 0
    var body = request.messagePreview !== null && request.messagePreview !== undefined
      ? "Clipboard text from " + sender
      : formatBytes(request.totalBytes) + " in " + count + (count === 1 ? " file" : " files") + " from " + sender
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "LocalSend",
      "--urgency", "normal",
      "--glyph", "󰒊",
      "Incoming LocalSend request",
      body,
      "--exec", "omarchy-shell", "-q", "shell", "summon", "anson.localsend"
    ])
  }

  function refresh() {
    queueRpc("refresh", ["refresh"], "Searching for nearby devices", false)
  }

  function chooseFiles() {
    startChooser("files")
  }

  function chooseFolder() {
    startChooser("folder")
  }

  function startChooser(mode) {
    if (chooserProcess.running) return
    _chooserMode = mode
    _chooserOutput = ""
    _chooserError = ""
    chooserProcess.command = mode === "folder"
      ? ["omarchy-file-select", "--title", "Share a folder with LocalSend", "--directory"]
      : ["omarchy-file-select", "--title", "Share files with LocalSend", "--multiple"]
    chooserProcess.running = true
  }

  function chooseClipboard() {
    payloadKind = "clipboard"
    selectedPaths = []
    payloadLabel = "Clipboard text"
    actionStatus = "Choose a nearby device"
    actionStatusTimer.restart()
  }

  function finishChooser(exitCode) {
    if (exitCode === 1) return
    if (exitCode !== 0) {
      lastError = concise(_chooserError || "File chooser failed")
      actionStatusTimer.restart()
      return
    }
    var lines = String(_chooserOutput || chooserStdout.text || "").replace(/\r/g, "").split("\n")
    var paths = []
    for (var i = 0; i < lines.length; i++) if (lines[i].length > 0) paths.push(lines[i])
    if (paths.length === 0) return
    payloadKind = "files"
    selectedPaths = paths
    payloadLabel = _chooserMode === "folder"
      ? "Folder: " + baseName(paths[0])
      : (paths.length === 1 ? baseName(paths[0]) : paths.length + " files selected")
    actionStatus = "Choose a nearby device"
    actionStatusTimer.restart()
    Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon", "anson.localsend"])
  }

  function clearPayload() {
    payloadKind = ""
    selectedPaths = []
    payloadLabel = ""
  }

  function sendToDevice(fingerprint) {
    var device = String(fingerprint || "")
    if (device === "" || payloadKind === "") return
    if (payloadKind === "clipboard") {
      queueRpc("send", ["send-clipboard", "--device", device], "Sending clipboard", true)
      return
    }
    var args = ["send-files", "--device", device]
    for (var i = 0; i < selectedPaths.length; i++) args.push("--path", String(selectedPaths[i]))
    queueRpc("send", args, "Transfer requested", true)
  }

  function acceptRequest(id) {
    queueRpc("accept", ["accept", "--request", String(id || "")], "Transfer accepted", false)
  }

  function declineRequest(id) {
    queueRpc("decline", ["decline", "--request", String(id || "")], "Transfer declined", false)
  }

  function cancelTransfer(id) {
    queueRpc("cancel", ["cancel", "--transfer", String(id || "")], "Cancelling transfer", false)
  }

  onControllerPathChanged: if (controllerPath !== "") launchTimer.restart()

  Component.onDestruction: {
    _intentionalStop = true
    restartTimer.stop()
    if (rpcProcess.running) rpcProcess.running = false
    if (chooserProcess.running) chooserProcess.running = false
    if (daemonProcess.running) daemonProcess.running = false
  }

  Timer {
    id: launchTimer
    interval: 100
    repeat: false
    onTriggered: root.startDaemon()
  }

  Timer {
    id: restartTimer
    interval: 1000
    repeat: false
    onTriggered: root.startDaemon()
  }

  Timer {
    id: startupTimeout
    interval: 10000
    repeat: false
    onTriggered: {
      if (!root.ready && daemonProcess.running) {
        root.lastError = "LocalSend receiver did not become ready"
        daemonProcess.running = false
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.incoming || root.hasActiveTransfer ? 450 : 1500
    repeat: true
    running: root.ready
    triggeredOnStart: true
    onTriggered: root.queueSnapshot()
  }

  Timer {
    id: rpcTimeout
    interval: 38000
    repeat: false
    onTriggered: {
      if (rpcProcess.running) {
        root._rpcTimedOut = true
        rpcProcess.running = false
      }
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: daemonProcess
    command: []
    running: false
    stdout: SplitParser { onRead: line => root.handleDaemonLine(line) }
    stderr: SplitParser {
      onRead: function(line) {
        var value = root.concise(line)
        if (value !== "" && !root.ready) root.lastError = value
      }
    }
    onStarted: {
      root.phase = "starting"
      startupTimeout.restart()
    }
    onExited: function(exitCode, exitStatus) {
      startupTimeout.stop()
      root.ready = false
      root.phase = "stopped"
      root.daemon = ({})
      root.devices = []
      root.incoming = null
      root.transfers = []
      root._rpcQueue = []
      root._snapshotQueued = false
      if (root._intentionalStop) return
      var immediate = root._restartRequested
      root._restartRequested = false
      root.scheduleRestart(immediate)
    }
  }

  Process {
    id: rpcProcess
    command: []
    running: false
    stdout: StdioCollector {
      id: rpcStdout
      waitForEnd: true
      onStreamFinished: root._rpcOutput = text
    }
    stderr: StdioCollector {
      id: rpcStderr
      waitForEnd: true
      onStreamFinished: root._rpcError = text
    }
    onExited: function(exitCode) { root.finishRpc(exitCode) }
  }

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    atomicWrites: false
    watchChanges: true
    printErrors: false
    onLoaded: root.loadShellConfig(text())
    onLoadFailed: root.pluginSettings = ({})
    onFileChanged: reload()
  }

  // Alias continuity with the headless lsend CLI: when no shell.json alias is
  // configured, use the same "Great Strawberry"-style name the CLI stores.
  FileView {
    id: aliasTxtFile
    path: root.aliasTxtPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      var value = String(text() || "").trim().split("\n")[0].trim()
      root.aliasTxtAlias = value.substring(0, 128)
    }
    onLoadFailed: root.aliasTxtAlias = ""
  }

  FileView {
    id: historyFile
    path: root.statePath
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: root.loadHistory(text())
    onLoadFailed: root.history = []
  }

  Process {
    id: chooserProcess
    command: []
    running: false
    stdout: StdioCollector {
      id: chooserStdout
      waitForEnd: true
      onStreamFinished: root._chooserOutput = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._chooserError = text
    }
    onExited: function(exitCode) { root.finishChooser(exitCode) }
  }
}
