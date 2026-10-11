// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import qs.services as OmarchyServices
import "LauncherModel.js" as LauncherModel

// The phone's home surface, after Omalauncher: one bar at the bottom of the
// screen that is app search, app grid and coding-agent prompt at once.
//
// Collapsed, it is a dock holding a single search pill. Tapping it raises the
// app drawer with the input focused. Typing filters the grid; text that reads
// like a sentence (or matches no app) offers "Ask <agent>" instead, and Enter
// takes whichever is on top: the first app, or a terminal running the agent
// with the text as its first prompt.
//
// Apps come from Omarchy's application library (services/AppLibrary.qml: the
// same entries, hidden-entry filters, icons and launch path as the Omarchy
// menu). The host shares its instance with `menu` plugins; see the Loader
// below for why this one is a `panel` that runs its own for now.
Item {
  id: root

  // Injected by the host.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "omarchy-mobile.launcher"
  readonly property var appLibrary: shell && shell.appLibrary ? shell.appLibrary : localLibrary.item

  // The host hands its application library only to `menu` plugins, and in
  // this Omarchy build a third-party menu loses its whole shell facade on the
  // next config change (phone/plugins/README.md has the details). So the
  // launcher declares `panel` and runs Omarchy's own AppLibrary type here: the
  // same entries, hidden-entry filters, icon index and launch path, in a
  // second instance. If the host ever provides one, that wins.
  Loader {
    id: localLibrary
    active: !!root.shell && !root.shell.appLibrary
    sourceComponent: Component { OmarchyServices.AppLibrary { } }
  }

  // `opened` is the drawer; the dock is always on screen.
  property bool opened: false
  property string query: ""
  property var apps: []
  property int appsRevision: 0

  // ---------------------------------------------------------------- settings

  property var shellConfig: ({})
  readonly property var settings: LauncherModel.mergedSettings(
    manifest && manifest.settings ? manifest.settings.defaults : ({}), shellConfig, pluginId)

  readonly property string agentName: String(settings.agentName || "Claude")
  readonly property var agentCommand: LauncherModel.argv(settings.agentCommand, ["claude"])
  readonly property var terminalCommand: LauncherModel.argv(settings.terminalCommand, ["xdg-terminal-exec"])
  readonly property string agentIcon: {
    var icon = String(settings.agentIcon || "")
    if (!icon) return ""
    return icon.charAt(0) === "/" ? Util.fileUrl(icon) : Util.fileUrl(omarchyPath + "/" + icon)
  }
  readonly property int columns: Math.max(3, Math.min(6, Number(settings.columns) || 4))
  readonly property int sentenceWords: Math.max(2, Number(settings.sentenceWords) || 3)

  // Plugin entries in shell.json carry their settings inline, but the host
  // only hands those to bar widgets, so read our own entry from the file.
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.shellConfig = JSON.parse(text() || "{}") } catch (e) { root.shellConfig = ({}) }
    }
  }

  // ---------------------------------------------------------------- results

  readonly property bool promptMode: LauncherModel.looksLikePrompt(query, apps.length, sentenceWords)
  readonly property bool hasQuery: query.trim().length > 0

  function refreshApps() {
    // sortedEntries() yields ranked rows of { entry, score, ... }; the grid
    // wants the DesktopEntry objects themselves.
    var rows = appLibrary ? appLibrary.sortedEntries(query) : []
    var entries = []
    for (var i = 0; i < rows.length; i++)
      if (rows[i] && rows[i].entry) entries.push(rows[i].entry)
    apps = entries
  }

  onQueryChanged: refreshApps()
  onAppLibraryChanged: refreshApps()

  Connections {
    target: root.appLibrary
    ignoreUnknownSignals: true
    function onAppsChanged() { root.refreshApps() }
  }

  // ---------------------------------------------------------------- actions

  function launchApp(entry) {
    if (!entry || !appLibrary) return
    appLibrary.launch(entry.id, appLibrary.entryName(entry))
    dismiss()
  }

  function askAgent(prompt) {
    var text = String(prompt || "").trim()
    if (!text) return "empty"
    Util.execArgv(LauncherModel.agentArgv(terminalCommand, agentCommand, text))
    dismiss()
    return "ok"
  }

  // Enter: the agent when the text reads as a prompt, else the top app.
  function activate() {
    if (!hasQuery) return
    if (promptMode || apps.length === 0) askAgent(query)
    else launchApp(apps[0])
  }

  // ---------------------------------------------------------------- lifecycle

  // `shell summon omarchy-mobile.launcher '{"query":"..."}'` opens the
  // drawer, optionally pre-filled.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    query = typeof payload.query === "string" ? payload.query : ""
    if (appLibrary) appLibrary.refreshIcons()
    refreshApps()
    opened = true
  }

  // Host-initiated close (`shell hide`).
  function close() {
    opened = false
    query = ""
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function expand() {
    if (shell && typeof shell.summon === "function") shell.summon(pluginId, "{}")
    else open("{}")
  }

  // `shell call omarchy-mobile.launcher <method> <arg>` entry points.
  function search(text) {
    if (!opened) expand()
    query = String(text || "")
    return JSON.stringify({ mode: promptMode ? "agent" : "apps", apps: apps.slice(0, 8).map(function(e) { return e.id }) })
  }

  function ask(prompt) { return askAgent(prompt) }

  function state() {
    return JSON.stringify({
      opened: opened,
      query: query,
      mode: hasQuery ? (promptMode ? "agent" : "apps") : "idle",
      apps: apps.length,
      library: shell && shell.appLibrary ? "host" : (appLibrary ? "local" : "none"),
      agent: agentName,
      command: LauncherModel.agentArgv(terminalCommand, agentCommand, "<prompt>")
    })
  }

  // ---------------------------------------------------------------- geometry

  readonly property color foreground: Color.menu.text
  readonly property int touch: Math.max(44, Style.space(44))
  readonly property int inputHeight: Math.max(48, Style.space(48))
  readonly property int dockHeight: inputHeight + Style.spacing.xxl * 2
  readonly property int barSize: shell && shell.bar ? shell.bar.barSize : 0

  property real reveal: opened ? 1 : 0
  Behavior on reveal { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

  // ---------------------------------------------------------------- dock

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData

      anchors { bottom: true; left: true; right: true }
      implicitHeight: root.dockHeight
      exclusionMode: ExclusionMode.Auto
      color: Color.bar.background
      WlrLayershell.namespace: "omarchy-mobile-dock"
      WlrLayershell.layer: WlrLayer.Top

      SearchPill {
        anchors.fill: parent
        anchors.margins: Style.spacing.xxl
        placeholder: "Search apps or ask " + root.agentName + "…"
        onTapped: root.expand()
      }
    }
  }

  // ---------------------------------------------------------------- drawer

  PanelWindow {
    id: drawer

    visible: root.opened || root.reveal > 0
    anchors { top: true; bottom: true; left: true; right: true }
    margins.top: root.barSize
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "omarchy-mobile-launcher"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    onVisibleChanged: if (visible) Qt.callLater(function() { input.forceActiveFocus() })

    Rectangle {
      id: sheet
      width: parent.width
      height: parent.height
      y: Math.round((1 - root.reveal) * Style.space(80))
      opacity: root.reveal
      color: Color.menu.background

      // ---------- Header: count and a collapse control
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.spacing.panelPadding
        anchors.rightMargin: Style.spacing.sm
        height: root.touch + Style.spacing.sm

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.hasQuery ? (root.apps.length === 1 ? "1 app" : root.apps.length + " apps") : "Apps"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Button {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: root.touch
          height: root.touch
          iconText: "󰅀"
          iconSize: Style.font.iconLarge
          foreground: root.foreground
          onClicked: root.dismiss()
        }
      }

      // ---------- App grid
      GridView {
        id: grid
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: askRow.visible ? askRow.top : inputRow.top
        anchors.leftMargin: Style.spacing.lg
        anchors.rightMargin: Style.spacing.lg
        anchors.bottomMargin: Style.spacing.lg
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // While searching, results stack up from the input so the best match
        // sits nearest the thumb; the full list reads top-down.
        verticalLayoutDirection: root.hasQuery ? GridView.BottomToTop : GridView.TopToBottom
        cellWidth: Math.floor(width / root.columns)
        cellHeight: Math.max(96, Style.space(100))
        model: root.apps
        opacity: root.promptMode ? 0.5 : 1

        delegate: AppCell {
          required property var modelData
          required property int index
          width: grid.cellWidth
          height: grid.cellHeight
          entry: modelData
          highlighted: index === 0 && root.hasQuery && !root.promptMode
          onTapped: root.launchApp(modelData)
        }
      }

      Text {
        anchors.centerIn: grid
        visible: root.hasQuery && root.apps.length === 0
        textFormat: Text.PlainText
        text: "No apps match"
        color: Qt.darker(root.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      // ---------- Ask the agent
      BorderSurface {
        id: askRow
        visible: root.hasQuery
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: inputRow.top
        anchors.leftMargin: Style.spacing.xxl
        anchors.rightMargin: Style.spacing.xxl
        anchors.bottomMargin: Style.spacing.lg
        height: Math.max(root.touch, Style.space(52))
        radius: Style.cornerRadius
        color: askTouch.pressed ? Style.pressedFillFor(root.foreground, Color.accent)
          : root.promptMode ? Color.menu.selectedBackground : "transparent"
        borderSpec: root.promptMode
          ? Border.flat(Color.accent, Math.max(1, Style.normalBorderWidth))
          : Border.controlSpec("normal", root.foreground, Color.accent)

        Item {
          id: askIcon
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.xl
          anchors.verticalCenter: parent.verticalCenter
          width: Style.font.display
          height: Style.font.display

          Image {
            id: askImage
            anchors.fill: parent
            source: root.agentIcon
            visible: status === Image.Ready
            fillMode: Image.PreserveAspectFit
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
          }

          Text {
            anchors.centerIn: parent
            visible: askImage.status !== Image.Ready
            textFormat: Text.PlainText
            text: "󰚩"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.display
          }
        }

        Column {
          anchors.left: askIcon.right
          anchors.leftMargin: Style.spacing.xl
          anchors.right: askEnter.left
          anchors.rightMargin: Style.spacing.lg
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Ask " + root.agentName
            color: root.promptMode ? Color.menu.selectedText : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.query.trim()
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          id: askEnter
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.xl
          anchors.verticalCenter: parent.verticalCenter
          visible: root.promptMode
          textFormat: Text.PlainText
          text: "󰌑"
          color: Color.menu.selectedText
          font.family: Style.font.family
          font.pixelSize: Style.font.iconLarge
        }

        MouseArea {
          id: askTouch
          anchors.fill: parent
          onClicked: root.askAgent(root.query)
        }
      }

      // ---------- The one input
      Item {
        id: inputRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.dockHeight

        TextField {
          id: input
          anchors.fill: parent
          anchors.margins: Style.spacing.xxl
          verticalAlignment: TextInput.AlignVCenter
          font.pixelSize: Style.font.title
          leftPadding: Style.spacing.controlPaddingX + Style.font.iconLarge + Style.spacing.xl
          placeholderText: "Search apps or ask " + root.agentName + "…"
          foreground: root.foreground
          text: root.query
          onTextEdited: root.query = text
          Keys.onReturnPressed: root.activate()
          Keys.onEnterPressed: root.activate()
          Keys.onEscapePressed: {
            if (root.query) root.query = ""
            else root.dismiss()
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX + Border.left(input._borderSpec)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.promptMode ? "󰚩" : "󰍉"
            color: root.promptMode ? Color.accent : Qt.darker(root.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- parts

  // The collapsed bar: looks like the input it turns into.
  component SearchPill: BorderSurface {
    id: pill

    property string placeholder: ""
    signal tapped()

    radius: Style.cornerRadius
    color: pillTouch.pressed ? Style.pressedFillFor(root.foreground, Color.accent) : Style.normalFill
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

    Text {
      id: pillIcon
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX + pill.borderLeft
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "󰍉"
      color: Qt.darker(root.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.iconLarge
    }

    Text {
      anchors.left: pillIcon.right
      anchors.leftMargin: Style.spacing.xl
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: pill.placeholder
      color: Qt.darker(root.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      elide: Text.ElideRight
    }

    MouseArea {
      id: pillTouch
      anchors.fill: parent
      onClicked: pill.tapped()
    }
  }

  // One app in the grid: icon over a two-line name.
  component AppCell: Item {
    id: cell

    property var entry: null
    property bool highlighted: false
    signal tapped()

    BorderSurface {
      anchors.fill: parent
      anchors.margins: Style.spacing.xs
      radius: Style.cornerRadius
      color: cellTouch.pressed ? Style.pressedFillFor(root.foreground, Color.accent)
        : cell.highlighted ? Color.menu.selectedBackground : "transparent"
      borderSpec: cell.highlighted ? Border.flat(Color.accent, Math.max(1, Style.normalBorderWidth)) : Border.none()
    }

    Image {
      id: icon
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.xl
      width: Math.max(40, Style.space(44))
      height: width
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      // Decode at physical pixels so PNG icons stay sharp at scale 3.
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      source: root.appLibrary && cell.entry ? root.appLibrary.iconSource(cell.entry.icon) : ""
    }

    Text {
      anchors.top: icon.bottom
      anchors.topMargin: Style.spacing.md
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.sm
      anchors.rightMargin: Style.spacing.sm
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: root.appLibrary && cell.entry ? root.appLibrary.entryName(cell.entry) : ""
      color: cell.highlighted ? Color.menu.selectedText : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }

    MouseArea {
      id: cellTouch
      anchors.fill: parent
      onClicked: cell.tapped()
    }
  }
}
