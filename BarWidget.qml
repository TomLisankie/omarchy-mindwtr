import QtQuick
import qs.Commons
import qs.Ui

// Mindwtr bar widget: a task-list icon with a bucket-count badge that opens a
// popup panel. Data fetching lives in the panel (it owns the fetch timer and
// stays mounted while closed), so this widget only renders its counts.
BarWidget {
  id: root
  moduleName: "mindwtr"

  readonly property var panel: panelLoader.item
  readonly property bool opened: panel ? panel.opened === true : false

  function togglePanel() { if (panel && panel.toggle) panel.toggle() }
  function open() { if (panel && panel.open) panel.open() }
  function close() { if (panel && panel.close) panel.close() }
  function refresh() { if (panel && panel.refresh) panel.refresh() }

  // Forwarded so the bar can treat this widget as the panel's popout identity.
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }

  property int focusCount: panel ? (panel.focusCount || 0) : 0
  property int inboxCount: panel ? (panel.inboxCount || 0) : 0
  property int nextCount: panel ? (panel.nextCount || 0) : 0
  property int waitingCount: panel ? (panel.waitingCount || 0) : 0
  property string statusText: panel ? (panel.statusText || "") : ""

  readonly property string badgeMode: String(setting("badge", "inbox"))
  readonly property bool showCount: setting("showCount", true) === true
  readonly property int displayedCount: badgeMode === "inbox" ? inboxCount
    : badgeMode === "next" ? nextCount
    : badgeMode === "waiting" ? waitingCount
    : focusCount

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function tooltip() {
    if (statusText !== "") return statusText
    return "Focus " + focusCount + "  \u00b7  Inbox " + inboxCount + "  \u00b7  Next " + nextCount + "  \u00b7  Waiting " + waitingCount
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0ae" // nf-fa-tasks
    tooltipText: root.tooltip()

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) root.close()
      else root.togglePanel()
    }
  }

  Rectangle {
    id: badge
    visible: root.showCount && root.displayedCount > 0
    anchors.top: button.top
    anchors.right: button.right
    z: 10

    readonly property string countLabel: root.displayedCount > 99 ? "99+" : String(root.displayedCount)

    implicitWidth: Math.max(Style.space(13), badgeText.implicitWidth + Style.space(5))
    implicitHeight: Style.space(13)
    radius: height / 2
    color: root.bar ? root.bar.urgent : Color.urgent
    border.width: 1
    border.color: root.bar ? root.bar.background : Color.background

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: badge.countLabel
      color: Color.background
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption * 0.85
      font.bold: true
      textFormat: Text.PlainText
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
