import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "clartek.omanextnews"
  ipcTarget: "clartek.omanextnews"
  manageIpc: false

  IpcHandler {
    target: "clartek.omanextnews"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function openArticleIndex(idx: int): void {
      if (root.displayedItems && root.displayedItems.length > idx) {
        root.openArticle(root.displayedItems[idx])
      }
    }
    function closeReader(): void {
      root.closeReader()
    }
  }

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property alias service: ncService

  // State
  property int selectedIndex: 0
  property string activeFilter: "unread" // "unread" | "all" | "starred"
  property int selectedFolderId: 0
  property int selectedFeedId: 0
  property string searchQuery: ""
  property var currentArticle: null
  property bool showSettings: false
  property string serverInputUrl: ncService.serverUrl || "https://nextcloud.clartek.cc"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var displayedItems: ncService.currentItems || []

  function open() {
    root.controller.show()
    if (ncService.authenticated) {
      refreshItems()
    } else {
      ncService.refreshStatus()
    }
  }

  function close() {
    currentArticle = null
    showSettings = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) close()
    else open()
  }

  function refreshItems() {
    ncService.loadItems(
      selectedFeedId,
      selectedFolderId,
      activeFilter === "starred",
      activeFilter === "unread",
      searchQuery,
      60
    )
  }

  function openArticle(item) {
    if (!item) return
    currentArticle = item
    if (item.unread) {
      ncService.markRead(item.id, true)
    }
  }

  function closeReader() {
    currentArticle = null
    refreshItems()
  }

  function openInBrowser(url) {
    if (!url) return
    Quickshell.execDetached(["omarchy", "launch", "browser", url])
  }

  function playMedia(url) {
    if (!url) return
    Quickshell.execDetached(["mpv", "--no-video", url])
  }

  Service {
    id: ncService
    settings: root.settings
    onAuthenticatedChanged: {
      if (authenticated) refreshItems()
    }
  }

  onActiveFilterChanged: { selectedIndex = 0; refreshItems() }
  onSelectedFolderIdChanged: { selectedIndex = 0; refreshItems() }
  onSelectedFeedIdChanged: { selectedIndex = 0; refreshItems() }
  onSearchQueryChanged: { selectedIndex = 0; refreshItems() }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(Style.space(580), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      clip: true

      onMoveRequested: function(dx, dy) {
        if (root.currentArticle) {
          if (dx < 0) root.closeReader()
          else if (dy !== 0) readerFlick.flick(0, -dy * 120)
          return
        }
        if (dy > 0 && root.selectedIndex < root.displayedItems.length - 1) {
          root.selectedIndex++
        } else if (dy < 0 && root.selectedIndex > 0) {
          root.selectedIndex--
        }
      }

      onActivateRequested: {
        if (!root.currentArticle && root.displayedItems.length > root.selectedIndex) {
          root.openArticle(root.displayedItems[root.selectedIndex])
        }
      }

      onCloseRequested: {
        if (root.currentArticle) root.closeReader()
        else if (root.showSettings) root.showSettings = false
        else root.close()
      }

      onTextKey: function(text) {
        if (root.currentArticle) {
          if (text === "escape" || text === "h") root.closeReader()
          else if (text === "o" || text === "O") root.openInBrowser(root.currentArticle.url)
          else if (text === "s" || text === "S") {
            ncService.toggleStar(root.currentArticle.id, root.currentArticle.starred)
            root.currentArticle.starred = root.currentArticle.starred ? 0 : 1
          } else if (text === "r" || text === "R") {
            ncService.markRead(root.currentArticle.id, !root.currentArticle.unread)
            root.currentArticle.unread = root.currentArticle.unread ? 0 : 1
          } else if ((text === "p" || text === "P") && root.currentArticle.enclosure_link) {
            root.playMedia(root.currentArticle.enclosure_link)
          }
          return
        }

        if (text === "j") {
          if (root.selectedIndex < root.displayedItems.length - 1) root.selectedIndex++
        } else if (text === "k") {
          if (root.selectedIndex > 0) root.selectedIndex--
        } else if (text === "o" || text === "O") {
          if (root.displayedItems.length > root.selectedIndex) {
            root.openInBrowser(root.displayedItems[root.selectedIndex].url)
          }
        } else if (text === "s" || text === "S") {
          if (root.displayedItems.length > root.selectedIndex) {
            var item = root.displayedItems[root.selectedIndex]
            ncService.toggleStar(item.id, item.starred)
          }
        } else if (text === "r" || text === "R") {
          if (root.displayedItems.length > root.selectedIndex) {
            var item2 = root.displayedItems[root.selectedIndex]
            ncService.markRead(item2.id, !item2.unread)
          }
        } else if (text === "m" || text === "M") {
          ncService.markAllRead(root.selectedFeedId, root.selectedFolderId)
        } else if (text === "u" || text === "U") {
          root.activeFilter = "unread"
        } else if (text === "a" || text === "A") {
          root.activeFilter = "all"
        } else if (text === "b" || text === "B") {
          root.activeFilter = "starred"
        }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(8)

        // ==========================================
        // TOP HEADER BAR
        // ==========================================
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(30)
          spacing: Style.space(6)

          NextcloudNewsIcon {
            iconSize: Style.space(16)
            color: Color.accent
            syncing: ncService.syncing
          }

          Text {
            text: "OmanewsNC"
            font.family: root.fontFamily
            font.pixelSize: Style.space(13)
            font.bold: true
            color: root.foreground
            elide: Text.ElideRight
          }

          // Live Unread Badge Pill
          Rectangle {
            visible: ncService.authenticated && ncService.unreadCount > 0
            Layout.preferredHeight: Style.space(16)
            Layout.preferredWidth: unreadText.implicitWidth + Style.space(8)
            radius: height / 2
            color: Color.accent

            Text {
              id: unreadText
              anchors.centerIn: parent
              text: String(ncService.unreadCount) + " unread"
              font.family: root.fontFamily
              font.pixelSize: Style.space(9)
              font.bold: true
              color: Color.background
            }
          }

          Item { Layout.fillWidth: true }

          // Header Action Buttons
          RowLayout {
            spacing: Style.space(3)

            // Mark all as read button
            PanelActionButton {
              visible: ncService.authenticated && !root.currentArticle && ncService.unreadCount > 0
              iconText: "✓"
              tooltipText: "Mark all as read"
              fontFamily: root.fontFamily
              onClicked: ncService.markAllRead(root.selectedFeedId, root.selectedFolderId)
            }

            // Sync button
            PanelActionButton {
              visible: ncService.authenticated
              iconText: "↻"
              tooltipText: ncService.syncing ? "Syncing feeds…" : "Sync feeds"
              fontFamily: root.fontFamily
              enabled: !ncService.syncing
              onClicked: ncService.sync()
            }

            // Settings / Account Toggle
            PanelActionButton {
              iconText: root.showSettings ? "✕" : "⚙"
              tooltipText: root.showSettings ? "Close settings" : "Account settings"
              fontFamily: root.fontFamily
              onClicked: root.showSettings = !root.showSettings
            }

            // Open Web News
            PanelActionButton {
              visible: ncService.authenticated
              iconText: "🌐"
              tooltipText: "Open Nextcloud News Web"
              fontFamily: root.fontFamily
              onClicked: {
                var sUrl = ncService.serverUrl || "https://nextcloud.clartek.cc"
                root.openInBrowser(sUrl + "/index.php/apps/news/")
              }
            }
          }
        }

        // ==========================================
        // SETTINGS / SIGN IN OVERLAY
        // ==========================================
        Rectangle {
          visible: !ncService.authenticated || root.showSettings
          Layout.fillWidth: true
          Layout.preferredHeight: settingsCol.implicitHeight + Style.space(16)
          radius: Style.space(8)
          color: Style.hoverFillFor(root.foreground, Color.accent)

          ColumnLayout {
            id: settingsCol
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(8)

            Text {
              text: ncService.authenticated ? "Account Connection" : "Connect to Nextcloud News"
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
              font.bold: true
              color: root.foreground
            }

            Text {
              visible: ncService.authenticated
              text: "Connected as: " + ncService.username + " (" + ncService.serverUrl + ")\nAuth method: " + ncService.authMethod
              font.family: root.fontFamily
              font.pixelSize: Style.space(10)
              color: root.dim
            }

            // Server URL input for login flow
            RowLayout {
              visible: !ncService.authenticated
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                text: "Server:"
                font.family: root.fontFamily
                font.pixelSize: Style.space(10)
                color: root.foreground
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(26)
                radius: Style.space(4)
                color: Color.background
                border.color: serverInput.activeFocus ? Color.accent : root.dim
                border.width: 1

                TextInput {
                  id: serverInput
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  text: root.serverInputUrl
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(10)
                  color: root.foreground
                  clip: true
                  onTextChanged: root.serverInputUrl = text
                }
              }
            }

            // Direct Browser Login Button
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Button {
                visible: !ncService.authenticated
                text: ncService.loggingIn ? "Waiting for browser authorization…" : "🔗 Sign in with Browser"
                fontSize: Style.space(10)
                enabled: !ncService.loggingIn
                onClicked: ncService.startLoginFlow(root.serverInputUrl)
              }

              Button {
                visible: ncService.authenticated
                text: "Disconnect Account"
                fontSize: Style.space(10)
                onClicked: {
                  ncService.logout()
                  root.showSettings = false
                }
              }
            }

            Text {
              visible: ncService.loggingIn
              text: "A browser tab was opened to grant access. After clicking 'Grant access', this panel will automatically log in."
              font.family: root.fontFamily
              font.pixelSize: Style.space(9)
              color: Color.accent
              wrapMode: Text.Wrap
              Layout.fillWidth: true
            }

            Text {
              visible: ncService.loginError !== ""
              text: "Error: " + ncService.loginError
              font.family: root.fontFamily
              font.pixelSize: Style.space(9.5)
              color: root.urgent
              wrapMode: Text.Wrap
              Layout.fillWidth: true
            }
          }
        }

        // ==========================================
        // SLIDING VIEW CONTAINER
        // ==========================================
        Item {
          id: viewport
          visible: ncService.authenticated && !root.showSettings
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true

          Item {
            id: track
            width: viewport.width * 2
            height: viewport.height
            x: root.currentArticle ? -viewport.width : 0

            Behavior on x {
              NumberAnimation {
                duration: 260
                easing.type: Easing.OutCubic
              }
            }

            // -------------------------------------------------------------
            // PAGE 0 (LEFT): ARTICLE LIST & FILTERS
            // -------------------------------------------------------------
            Item {
              id: listPage
              width: viewport.width
              height: parent.height
              x: 0

              ColumnLayout {
                anchors.fill: parent
                spacing: Style.space(6)

                // Segmented Filter: Unread | All | Starred
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  Repeater {
                    model: [
                      { id: "unread", label: "Unread" },
                      { id: "all", label: "All" },
                      { id: "starred", label: "★ Starred" }
                    ]

                    Rectangle {
                      Layout.fillWidth: true
                      Layout.preferredHeight: Style.space(24)
                      radius: Style.space(6)
                      color: root.activeFilter === modelData.id ? Color.accent : Style.hoverFillFor(root.foreground, Color.accent)

                      Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        font.family: root.fontFamily
                        font.pixelSize: Style.space(10)
                        font.bold: root.activeFilter === modelData.id
                        color: root.activeFilter === modelData.id ? Color.background : root.foreground
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activeFilter = modelData.id
                      }
                    }
                  }
                }

                // Category / Folder Pills (Horizontal scroll)
                Flickable {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(24)
                  contentWidth: folderRow.implicitWidth
                  boundsBehavior: Flickable.StopAtBounds
                  flickableDirection: Flickable.HorizontalFlick
                  clip: true

                  Row {
                    id: folderRow
                    spacing: Style.space(4)

                    // All Feeds Pill
                    Rectangle {
                      height: Style.space(22)
                      width: allFeedsText.implicitWidth + Style.space(12)
                      radius: height / 2
                      color: root.selectedFolderId === 0 && root.selectedFeedId === 0 ? root.foreground : Style.hoverFillFor(root.foreground, Color.accent)

                      Text {
                        id: allFeedsText
                        anchors.centerIn: parent
                        text: "All Feeds"
                        font.family: root.fontFamily
                        font.pixelSize: Style.space(9)
                        color: root.selectedFolderId === 0 && root.selectedFeedId === 0 ? Color.background : root.foreground
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.selectedFolderId = 0; root.selectedFeedId = 0 }
                      }
                    }

                    // Folder Pills
                    Repeater {
                      model: ncService.folders || []
                      Rectangle {
                        height: Style.space(22)
                        width: folderLabel.implicitWidth + Style.space(12)
                        radius: height / 2
                        color: root.selectedFolderId === modelData.id ? root.foreground : Style.hoverFillFor(root.foreground, Color.accent)

                        Text {
                          id: folderLabel
                          anchors.centerIn: parent
                          text: modelData.name
                          font.family: root.fontFamily
                          font.pixelSize: Style.space(9)
                          color: root.selectedFolderId === modelData.id ? Color.background : root.foreground
                        }
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.selectedFeedId = 0
                            root.selectedFolderId = (root.selectedFolderId === modelData.id) ? 0 : modelData.id
                          }
                        }
                      }
                    }
                  }
                }

                // Search Field
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(26)
                  radius: Style.space(6)
                  color: Style.hoverFillFor(root.foreground, Color.accent)
                  border.color: searchInput.activeFocus ? Color.accent : "transparent"
                  border.width: 1

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)

                    Text {
                      text: "🔍"
                      font.pixelSize: Style.space(10)
                    }

                    TextInput {
                      id: searchInput
                      Layout.fillWidth: true
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.space(10)
                      clip: true
                      Text {
                        anchors.fill: parent
                        visible: !searchInput.text && !searchInput.activeFocus
                        text: "Search articles or author…"
                        color: root.dim
                        font.family: searchInput.font.family
                        font.pixelSize: searchInput.font.pixelSize
                      }
                      onTextChanged: root.searchQuery = text
                    }

                    Text {
                      visible: searchInput.text !== ""
                      text: "✕"
                      color: root.dim
                      font.pixelSize: Style.space(10)
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: searchInput.text = ""
                      }
                    }
                  }
                }

                // Article List Scroll Area
                Flickable {
                  id: listFlick
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  contentWidth: width
                  contentHeight: articlesCol.implicitHeight
                  boundsBehavior: Flickable.StopAtBounds
                  flickableDirection: Flickable.VerticalFlick
                  clip: true
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  Column {
                    id: articlesCol
                    width: listFlick.width - Style.space(10)
                    spacing: Style.space(6)

                    // Caught Up Placeholder
                    Rectangle {
                      visible: root.displayedItems.length === 0
                      width: parent.width
                      height: Style.space(180)
                      radius: Style.space(8)
                      color: Style.hoverFillFor(root.foreground, Color.accent)

                      ColumnLayout {
                        anchors.centerIn: parent
                        spacing: Style.space(8)

                        Text {
                          Layout.alignment: Qt.AlignHCenter
                          text: "🎉"
                          font.pixelSize: Style.space(32)
                        }

                        Text {
                          Layout.alignment: Qt.AlignHCenter
                          text: ncService.itemsLoading ? "Loading articles…" : "All Caught Up!"
                          font.family: root.fontFamily
                          font.pixelSize: Style.space(14)
                          font.bold: true
                          color: root.foreground
                        }

                        Text {
                          Layout.alignment: Qt.AlignHCenter
                          text: ncService.itemsLoading ? "Fetching latest feeds from Nextcloud" : "No unread articles in this view."
                          font.family: root.fontFamily
                          font.pixelSize: Style.space(10)
                          color: root.dim
                        }
                      }
                    }

                    // Article Cards
                    Repeater {
                      model: root.displayedItems

                      Rectangle {
                        id: card
                        width: articlesCol.width
                        height: cardCol.implicitHeight + Style.space(16)
                        radius: Style.space(8)
                        property bool isSelected: index === root.selectedIndex
                        color: isSelected ? Style.selectedFillFor(root.foreground, Color.accent) : Style.hoverFillFor(root.foreground, Color.accent)
                        border.color: isSelected ? Color.accent : "transparent"
                        border.width: isSelected ? 1.5 : 0

                        ColumnLayout {
                          id: cardCol
                          anchors.fill: parent
                          anchors.margins: Style.space(10)
                          spacing: Style.space(4)

                          // Feed name, Relative Date, Actions
                          RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(6)

                            Rectangle {
                              visible: modelData.unread === 1
                              width: Style.space(6)
                              height: width
                              radius: width / 2
                              color: Color.accent
                            }

                            Image {
                              source: modelData.feed_favicon || ""
                              Layout.preferredWidth: Style.space(12)
                              Layout.preferredHeight: Style.space(12)
                              fillMode: Image.PreserveAspectFit
                              visible: status === Image.Ready
                            }

                            Text {
                              text: Model.decodeEntities(modelData.feed_title || "Feed")
                              font.family: root.fontFamily
                              font.pixelSize: Style.space(9)
                              font.bold: true
                              color: Color.accent
                              elide: Text.ElideRight
                              Layout.maximumWidth: Style.space(180)
                            }

                            Text {
                              text: "· " + Model.relativeTime(modelData.pub_date)
                              font.family: root.fontFamily
                              font.pixelSize: Style.space(9)
                              color: root.dim
                            }

                            Item { Layout.fillWidth: true }

                            // Star Button
                            Text {
                              text: modelData.starred ? "★" : "☆"
                              font.pixelSize: Style.space(12)
                              color: modelData.starred ? "#f59e0b" : root.dim
                              MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: ncService.toggleStar(modelData.id, modelData.starred)
                              }
                            }

                            // Read/Unread Bullet
                            Text {
                              text: modelData.unread ? "●" : "○"
                              font.pixelSize: Style.space(10)
                              color: modelData.unread ? Color.accent : root.dim
                              MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: ncService.markRead(modelData.id, !modelData.unread)
                              }
                            }
                          }

                          // Article Title
                          Text {
                            Layout.fillWidth: true
                            text: Model.decodeEntities(modelData.title || "Untitled")
                            font.family: root.fontFamily
                            font.pixelSize: Style.space(12)
                            font.bold: modelData.unread === 1
                            color: modelData.unread === 1 ? root.foreground : root.dim
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                          }

                          // Snippet
                          Text {
                            Layout.fillWidth: true
                            visible: modelData.snippet !== ""
                            text: Model.decodeEntities(modelData.snippet || "")
                            font.family: root.fontFamily
                            font.pixelSize: Style.space(9.5)
                            color: root.dim
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                          }
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.selectedIndex = index
                            root.openArticle(modelData)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // -------------------------------------------------------------
            // PAGE 1 (RIGHT): FULL ARTICLE READER VIEW
            // -------------------------------------------------------------
            Item {
              id: readerPage
              width: viewport.width
              height: parent.height
              x: viewport.width

              ColumnLayout {
                anchors.fill: parent
                spacing: Style.space(8)

                // Reader Top Action Bar
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Button {
                    text: "← Back"
                    fontSize: Style.space(10)
                    onClicked: root.closeReader()
                  }

                  Item { Layout.fillWidth: true }

                  Button {
                    text: root.currentArticle && root.currentArticle.starred ? "★ Starred" : "☆ Star"
                    fontSize: Style.space(10)
                    onClicked: {
                      if (root.currentArticle) {
                        ncService.toggleStar(root.currentArticle.id, root.currentArticle.starred)
                        root.currentArticle.starred = root.currentArticle.starred ? 0 : 1
                      }
                    }
                  }

                  Button {
                    text: root.currentArticle && root.currentArticle.unread ? "Mark read" : "Mark unread"
                    fontSize: Style.space(10)
                    onClicked: {
                      if (root.currentArticle) {
                        ncService.markRead(root.currentArticle.id, !root.currentArticle.unread)
                        root.currentArticle.unread = root.currentArticle.unread ? 0 : 1
                      }
                    }
                  }

                  Button {
                    text: "Open original ↗"
                    fontSize: Style.space(10)
                    onClicked: {
                      if (root.currentArticle) root.openInBrowser(root.currentArticle.url)
                    }
                  }
                }

                // Article Meta Header
                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: metaCol.implicitHeight + Style.space(12)
                  radius: Style.space(6)
                  color: Style.hoverFillFor(root.foreground, Color.accent)

                  ColumnLayout {
                    id: metaCol
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    spacing: Style.space(4)

                    Text {
                      Layout.fillWidth: true
                      text: root.currentArticle ? root.currentArticle.title : ""
                      font.family: root.fontFamily
                      font.pixelSize: Style.space(13.5)
                      font.bold: true
                      color: root.foreground
                      wrapMode: Text.Wrap
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Text {
                        text: root.currentArticle ? (root.currentArticle.feed_title || "Feed") : ""
                        font.bold: true
                        font.pixelSize: Style.space(9.5)
                        color: Color.accent
                      }

                      Text {
                        visible: root.currentArticle && !!root.currentArticle.author
                        text: "by " + (root.currentArticle ? root.currentArticle.author : "")
                        font.pixelSize: Style.space(9.5)
                        color: root.dim
                      }

                      Text {
                        text: "· " + (root.currentArticle ? Model.formatFullDate(root.currentArticle.pub_date) : "")
                        font.pixelSize: Style.space(9.5)
                        color: root.dim
                      }
                    }

                    // Podcast enclosure player
                    RowLayout {
                      visible: root.currentArticle && root.currentArticle.enclosure_mime && root.currentArticle.enclosure_mime.indexOf("audio") !== -1
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Button {
                        text: "▶ Play Podcast (MPV)"
                        fontSize: Style.space(9.5)
                        onClicked: {
                          if (root.currentArticle && root.currentArticle.enclosure_link) {
                            root.playMedia(root.currentArticle.enclosure_link)
                          }
                        }
                      }
                      Text {
                        text: "Audio episode attached"
                        color: root.dim
                        font.pixelSize: Style.space(9)
                      }
                    }
                  }
                }

                // Scrollable Article Body
                Flickable {
                  id: readerFlick
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  contentWidth: width
                  contentHeight: bodyText.implicitHeight + Style.space(20)
                  boundsBehavior: Flickable.StopAtBounds
                  clip: true
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  Text {
                    id: bodyText
                    width: readerFlick.width - Style.space(12)
                    text: root.currentArticle ? Model.sanitizeForQml(root.currentArticle.body) : ""
                    textFormat: Text.RichText
                    wrapMode: Text.Wrap
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(11)
                    color: root.foreground
                    onLinkActivated: function(link) { root.openInBrowser(link) }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
