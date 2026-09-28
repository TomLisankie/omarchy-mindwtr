import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Mindwtr popup panel. Owns all server IO for the plugin: the bar widget is a
// thin renderer of the counts this panel exposes. The panel stays mounted
// while closed, so the refresh timer keeps the badge fresh.
Panel {
  id: root
  moduleName: "mindwtr"
  ipcTarget: "mindwtr"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot, not this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string scriptPath: Qt.resolvedUrl("mindwtr-api.sh").toString().replace(/^file:\/\//, "")

  // ---- server state -------------------------------------------------------
  property var summary: null
  property bool loading: false
  property string errorText: ""
  property string activeTab: "focus"

  property string captureText: ""
  property bool capturing: false
  property string toast: ""
  property bool toastIsError: false

  readonly property var tabs: [
    { key: "focus", label: "Focus" },
    { key: "inbox", label: "Inbox" },
    { key: "next", label: "Next" },
    { key: "waiting", label: "Waiting" },
    { key: "someday", label: "Someday" }
  ]

  readonly property int focusCount: summary ? (summary.counts.focus || 0) : 0
  readonly property int inboxCount: summary ? (summary.counts.inbox || 0) : 0
  readonly property int nextCount: summary ? (summary.counts.next || 0) : 0
  readonly property int waitingCount: summary ? (summary.counts.waiting || 0) : 0
  readonly property int somedayCount: summary ? (summary.counts.someday || 0) : 0

  readonly property int refreshSecs: Math.max(30, parseInt(setting("refreshIntervalSec", 120), 10) || 120)
  readonly property bool quickAddEnabled: setting("quickAdd", true) === true
  readonly property bool completeOnClick: setting("completeOnClick", true) === true
  readonly property var activeTasks: (summary && summary[activeTab]) ? summary[activeTab] : []

  readonly property string serverLabel: summary && summary.server !== "" ? summary.server : "Mindwtr"
  readonly property string statusText: {
    if (errorText !== "") return errorText
    if (loading && !summary) return "Loading\u2026"
    return "Focus " + focusCount + "  \u00b7  Inbox " + inboxCount + "  \u00b7  Next " + nextCount + "  \u00b7  Waiting " + waitingCount
  }

  // ---- lifecycle (mirrors the first-party popup panels) -------------------
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- data ---------------------------------------------------------------
  function refresh() {
    if (summaryProc.running) return
    loading = true
    summaryProc.command = ["bash", root.scriptPath, "summary"]
    summaryProc.running = true
  }

  function handleSummary(raw) {
    loading = false
    var parsed = Model.parseSummary(raw)
    if (!parsed.ok) {
      errorText = Model.errorText(parsed.error)
      return
    }
    errorText = ""
    summary = parsed
  }

  function showToast(message, isError) {
    toast = message
    toastIsError = isError === true
    toastTimer.restart()
  }

  function submitCapture() {
    if (!quickAddEnabled || capturing) return
    var text = String(captureText).replace(/^\s+|\s+$/g, "")
    if (text === "") return
    capturing = true
    captureProc.command = ["bash", root.scriptPath, "capture", text]
    captureProc.running = true
  }

  function completeTask(task) {
    if (!completeOnClick || !task || task.id === "" || completeProc.running) return
    completeProc.command = ["bash", root.scriptPath, "complete", String(task.id)]
    completeProc.running = true
  }

  function selectTab(key) {
    activeTab = String(key)
  }

  // ---- IO -----------------------------------------------------------------
  Process {
    id: summaryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSummary(text)
    }
    onRunningChanged: if (!running && root.loading) root.loading = false
  }

  Process {
    id: captureProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseMutation(text)
        if (parsed.ok) {
          root.captureText = ""
          root.showToast("Captured", false)
          Qt.callLater(root.refresh)
        } else {
          root.showToast(Model.errorText(parsed.error), true)
        }
      }
    }
    onRunningChanged: if (!running) root.capturing = false
  }

  Process {
    id: completeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseMutation(text)
        if (parsed.ok) {
          root.showToast("Completed", false)
          Qt.callLater(root.refresh)
        } else {
          root.showToast(Model.errorText(parsed.error), true)
        }
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshSecs * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: toastTimer
    interval: 2600
    onTriggered: { root.toast = ""; root.toastIsError = false }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // ---- UI -----------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(bodyColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: captureField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: captureField.forceActiveFocus()

      Column {
        id: bodyColumn
        width: parent.width
        spacing: Style.space(10)

        // ---- header
        Item {
          width: parent.width
          height: Style.space(26)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Mindwtr"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            textFormat: Text.PlainText
          }

          Text {
            anchors.left: titleText.right
            anchors.leftMargin: Style.space(8)
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.serverLabel
            color: Color.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            elide: Text.ElideRight
          }

          Rectangle {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            height: Style.space(22)
            radius: Math.min(5, Style.cornerRadius)
            color: refreshMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "\uf021"
              color: root.loading ? Color.muted : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            MouseArea {
              id: refreshMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refresh()
            }
          }
        }

        // ---- bucket tabs
        Row {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.tabs

            Rectangle {
              required property var modelData
              required property int index
              readonly property bool selected: root.activeTab === modelData.key
              readonly property int count: root.summary && root.summary.counts ? (root.summary.counts[modelData.key] || 0) : 0

              width: tabContent.implicitWidth + Style.space(16)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: tabMouse.containsMouse && !selected
                ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                : (selected ? Util.alpha(Color.accent, 0.18) : "transparent")

              Row {
                id: tabContent
                anchors.centerIn: parent
                spacing: Style.space(5)

                Text {
                  text: modelData.label
                  color: selected ? Color.accent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: selected
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  visible: count > 0
                  text: String(count)
                  color: selected ? Color.accent : Color.muted
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectTab(modelData.key)
              }
            }
          }
        }

        // ---- error / toast line
        Text {
          visible: text !== ""
          width: parent.width
          text: root.errorText !== "" ? root.errorText : root.toast
          color: root.errorText !== "" || root.toastIsError ? Color.urgent : Color.muted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }

        // ---- task list
        Flickable {
          id: listFlick
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(360))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(2)

            Repeater {
              model: root.activeTasks

              Rectangle {
                required property var modelData
                required property int index
                readonly property bool overdue: Model.isOverdue(modelData)
                readonly property string meta: Model.subtitle(modelData)

                width: listColumn.width
                height: taskColumn.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: taskMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Text {
                    visible: root.completeOnClick
                    text: taskMouse.containsMouse ? "\uf00c" : (modelData.focused ? "\uf005" : "\uf111")
                    color: taskMouse.containsMouse ? Color.accent : Color.muted
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(14)
                    horizontalAlignment: Text.AlignHCenter
                  }

                  Column {
                    id: taskColumn
                    width: parent.width - Style.space(30)
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: modelData.title
                      color: overdue ? Color.urgent : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: meta !== ""
                      width: parent.width
                      text: meta
                      color: overdue ? Color.urgent : Color.muted
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                  }
                }

                MouseArea {
                  id: taskMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: root.completeOnClick ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.completeTask(modelData)
                }
              }
            }

            Text {
              visible: root.activeTasks.length === 0
              width: listColumn.width
              height: Style.space(64)
              text: root.loading ? "Loading\u2026"
                : root.errorText !== "" ? "No data"
                : "Nothing in " + root.activeTab
              color: Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
          }
        }

        // ---- quick capture
        Row {
          visible: root.quickAddEnabled
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: captureField
            width: parent.width - addButton.width - Style.space(8)
            placeholderText: "Capture to Inbox\u2026  (@context, #project, tomorrow)"
            foreground: root.bar.foreground
            enabled: !root.capturing

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitCapture()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
              }
            }
          }

          Rectangle {
            id: addButton
            width: Style.space(30)
            height: captureField.height
            radius: Style.cornerRadius
            color: addMouse.containsMouse && captureField.text !== ""
              ? Style.hoverFillFor(root.bar.foreground, Color.accent)
              : "transparent"
            border.width: 1
            border.color: Util.alpha(root.bar.foreground, 0.25)

            Text {
              anchors.centerIn: parent
              text: root.capturing ? "\u2026" : "\uf067"
              color: captureField.text !== "" ? root.bar.foreground : Color.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            MouseArea {
              id: addMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.submitCapture()
            }
          }
        }

        // ---- footer
        Text {
          width: parent.width
          text: {
            if (root.errorText !== "" && !root.summary) return "Set the server in ~/.config/omarchy/mindwtr.json"
            var when = root.summary && root.summary.fetchedAt !== "" ? root.summary.fetchedAt.replace("T", " ").replace("Z", " UTC") : ""
            return when === "" ? "" : "Updated " + when
          }
          color: Color.muted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          elide: Text.ElideRight
        }
      }
    }
  }
}
