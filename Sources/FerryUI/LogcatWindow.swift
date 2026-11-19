import DeviceKit
import SwiftUI

/// A device's log: the level and text filters, Pause, Clear and Save… above the lines, which
/// follow the end of the log unless it is paused, and a line below with how many are shown. The
/// stream stops when the window closes.
public struct LogcatWindow: View {
  public static let windowID = DeveloperWindow.logcat.windowID
  public static let windowTitle = Text("Logcat", bundle: .module)

  @State private var session: LogcatSession
  private let title: String

  public init(model: AppModel, device: DeviceID) {
    _session = State(initialValue: model.logcatSession(for: device))
    title = model.windowName(of: device)
  }

  public var body: some View {
    @Bindable var session = session
    VStack(spacing: 0) {
      HStack {
        Picker(selection: $session.minimumLevel) {
          ForEach(LogcatEntry.Level.allCases, id: \.self) { level in
            Text(LogcatWindow.levelName(level))
              .tag(level)
          }
        } label: {
          Text("Level", bundle: .module)
        }
        .fixedSize()
        TextField(text: $session.filterText, prompt: Text("Filter", bundle: .module)) {
          Text("Filter", bundle: .module)
        }
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 140, maxWidth: 260)
        Spacer()
        Button {
          session.togglePause()
        } label: {
          if session.isPaused {
            Label {
              Text("Resume", bundle: .module)
            } icon: {
              Image(systemName: "play.fill")
            }
          } else {
            Label {
              Text("Pause", bundle: .module)
            } icon: {
              Image(systemName: "pause.fill")
            }
          }
        }
        Button {
          session.clear()
        } label: {
          Text("Clear", bundle: .module)
        }
        Button {
          Task { await session.save() }
        } label: {
          Text("Save…", bundle: .module)
        }
      }
      .padding(10)
      Divider()
      lines
      Divider()
      HStack {
        Text(
          DevicePresentation.logCountLine(shown: session.shown.count, held: session.held)
        )
        .foregroundStyle(.secondary)
        if case .ended(let message) = session.state {
          Text(verbatim: message)
            .foregroundStyle(.red)
          Button {
            Task { await session.run() }
          } label: {
            Text("Restart", bundle: .module)
          }
        }
        if let error = session.saveError {
          Text(verbatim: error)
            .foregroundStyle(.red)
        }
        Spacer()
      }
      .font(.callout)
      .padding(8)
    }
    .frame(minWidth: 560, minHeight: 320)
    .navigationTitle(Text(verbatim: DevicePresentation.logTitle(name: title)))
    .task { await session.run() }
    .onDisappear { Task { await session.close() } }
  }

  /// The lines, newest last. The view scrolls to the end as lines arrive, unless paused.
  private var lines: some View {
    ScrollViewReader { proxy in
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(session.shown) { entry in
            Text(verbatim: DisplayText.escaped(entry.text))
              .font(.system(.callout, design: .monospaced))
              .foregroundStyle(Self.color(of: entry.level))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.endID)
        }
        .padding(.horizontal, 10)
      }
      .onChange(of: session.shown.last?.id) { _, _ in
        if !session.isPaused { proxy.scrollTo(Self.endID, anchor: .bottom) }
      }
    }
    .accessibilityLabel(Text("Log lines", bundle: .module))
    .accessibilityValue(
      Text(DevicePresentation.logCountLine(shown: session.shown.count, held: session.held)))
  }

  private static let endID = "end-of-log"

  /// Warnings and errors stand out by colour and, for everyone else, by the level letter the
  /// line itself carries.
  private static func color(of level: LogcatEntry.Level?) -> Color {
    switch level {
    case .warning: .orange
    case .error, .fatal: .red
    case .verbose, .debug: .secondary
    case .info, nil: .primary
    }
  }

  static func levelName(_ level: LogcatEntry.Level) -> LocalizedStringResource {
    switch level {
    case .verbose: LocalizedStringResource("Verbose", bundle: .module)
    case .debug: LocalizedStringResource("Debug", bundle: .module)
    case .info: LocalizedStringResource("Info", bundle: .module)
    case .warning: LocalizedStringResource("Warning", bundle: .module)
    case .error: LocalizedStringResource("Error", bundle: .module)
    case .fatal: LocalizedStringResource("Fatal", bundle: .module)
    }
  }
}
