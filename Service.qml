import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool statusKnown: false
  property bool authenticated: false
  property string authMethod: "none"
  property string serverUrl: ""
  property string username: ""
  property bool loggingIn: false
  property string loginError: ""

  property bool syncing: false
  property bool syncError: false
  property string lastError: ""
  property int unreadCount: 0
  property int starredCount: 0
  property double lastSyncTs: 0
  property var folders: []
  property var feeds: []
  property var currentItems: []
  property bool itemsLoading: false

  readonly property string helperPath: Model.filePath(Qt.resolvedUrl("news_backend.py"))
  readonly property int refreshIntervalMs: {
    var min = settings && typeof settings.refreshIntervalMin === "number" ? settings.refreshIntervalMin : 15
    return Math.max(1, Math.min(180, min)) * 60 * 1000
  }

  function startLoginFlow(targetServer) {
    if (loginProcess.running || helperPath === "") return
    loggingIn = true
    loginError = ""
    var cmd = ["python3", helperPath, "--login-flow"]
    if (targetServer && targetServer.trim() !== "") {
      cmd.push("--server-url", targetServer.trim())
    }
    loginProcess.command = cmd
    loginProcess.running = true
  }

  function logout() {
    if (helperPath === "") return
    Quickshell.execDetached(["python3", helperPath, "--logout"])
    authenticated = false
    authMethod = "none"
    unreadCount = 0
    starredCount = 0
    folders = []
    feeds = []
    currentItems = []
    refreshStatus()
  }

  function sync() {
    if (syncProcess.running || helperPath === "" || !authenticated) return
    syncing = true
    syncError = false
    lastError = ""
    var cmd = ["python3", helperPath, "--sync"]
    if (settings && settings.notificationsEnabled === false) {
      cmd.push("--no-notify")
    }
    syncProcess.command = cmd
    syncProcess.running = true
  }

  function refreshStatus() {
    if (statusProcess.running || helperPath === "") return
    statusProcess.command = ["python3", helperPath, "--status"]
    statusProcess.running = true
  }

  function loadItems(feedId, folderId, starred, unread, search, limit) {
    if (itemsProcess.running || helperPath === "") return
    itemsLoading = true
    var cmd = ["python3", helperPath, "--items"]
    if (feedId > 0) cmd.push("--feed-id", String(feedId))
    else if (folderId > 0) cmd.push("--folder-id", String(folderId))
    if (starred) cmd.push("--starred")
    if (unread) cmd.push("--unread")
    if (search && search.trim() !== "") cmd.push("--search", search.trim())
    cmd.push("--limit", String(limit || 50))

    itemsProcess.command = cmd
    itemsProcess.running = true
  }

  function markRead(itemId, read) {
    if (helperPath === "" || !itemId) return
    for (var i = 0; i < currentItems.length; i++) {
      if (currentItems[i].id === itemId) {
        currentItems[i].unread = read ? 0 : 1
        break
      }
    }
    currentItems = currentItems.slice()
    if (read && unreadCount > 0) unreadCount--
    else if (!read) unreadCount++

    var cmd = ["python3", helperPath, read ? "--mark-read" : "--mark-unread", String(itemId)]
    Quickshell.execDetached(cmd)
  }

  function toggleStar(itemId, currentStarred) {
    if (helperPath === "" || !itemId) return
    var newStarred = !currentStarred
    for (var i = 0; i < currentItems.length; i++) {
      if (currentItems[i].id === itemId) {
        currentItems[i].starred = newStarred ? 1 : 0
        break
      }
    }
    currentItems = currentItems.slice()
    if (newStarred) starredCount++
    else if (starredCount > 0) starredCount--

    var cmd = ["python3", helperPath, newStarred ? "--star" : "--unstar", String(itemId)]
    Quickshell.execDetached(cmd)
  }

  function markAllRead(feedId, folderId) {
    if (helperPath === "") return
    for (var i = 0; i < currentItems.length; i++) {
      currentItems[i].unread = 0
    }
    currentItems = currentItems.slice()
    unreadCount = 0

    var cmd = ["python3", helperPath, "--mark-all-read"]
    if (feedId > 0) cmd.push("--feed-id", String(feedId))
    else if (folderId > 0) cmd.push("--folder-id", String(folderId))
    Quickshell.execDetached(cmd)
    delayedRefresh.restart()
  }

  function applyStatus(data) {
    statusKnown = true
    if (!data || !data.ok) {
      authenticated = false
      syncError = true
      lastError = data ? (data.error || "Status error") : "Empty status"
      return
    }
    syncError = false
    lastError = ""
    authenticated = !!data.authenticated
    authMethod = data.authMethod || "none"
    serverUrl = data.serverUrl || ""
    username = data.user || ""
    unreadCount = data.unreadCount || 0
    starredCount = data.starredCount || 0
    lastSyncTs = data.lastSync || 0
    folders = data.folders || []
    feeds = data.feeds || []
  }

  Timer {
    id: autoSyncTimer
    interval: root.refreshIntervalMs
    running: root.authenticated
    repeat: true
    triggeredOnStart: false
    onTriggered: root.sync()
  }

  Timer {
    id: delayedRefresh
    interval: 800
    repeat: false
    onTriggered: root.refreshStatus()
  }

  Component.onCompleted: {
    refreshStatus()
    Qt.callLater(function() {
      if (root.authenticated && root.lastSyncTs <= 0) root.sync()
    })
  }

  // Login Process
  Process {
    id: loginProcess
    running: false
    command: []
    stdout: StdioCollector { id: loginOut; waitForEnd: true }
    stderr: StdioCollector { id: loginErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loggingIn = false
      if (exitCode === 0) {
        var parsed = Model.parseJson(loginOut.text)
        if (parsed.ok) {
          root.authenticated = true
          root.refreshStatus()
        } else {
          root.loginError = parsed.error || "Login failed"
        }
      } else {
        root.loginError = String(loginErr.text || loginOut.text || "Login timed out or failed").trim()
      }
    }
  }

  // Status Process
  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = Model.parseJson(statusOut.text)
        root.applyStatus(parsed)
      }
    }
  }

  // Sync Process
  Process {
    id: syncProcess
    running: false
    command: []
    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    stderr: StdioCollector { id: syncErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.syncing = false
      if (exitCode === 0) {
        var parsed = Model.parseJson(syncOut.text)
        root.applyStatus(parsed)
      } else {
        root.syncError = true
        root.lastError = String(syncErr.text || syncOut.text || "Sync failed").trim()
      }
    }
  }

  // Items Process
  Process {
    id: itemsProcess
    running: false
    command: []
    stdout: StdioCollector { id: itemsOut; waitForEnd: true }
    stderr: StdioCollector { id: itemsErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.itemsLoading = false
      if (exitCode === 0) {
        var parsed = Model.parseJson(itemsOut.text)
        if (parsed.ok && Array.isArray(parsed.items)) {
          root.currentItems = parsed.items
        }
      }
    }
  }
}
