import MactionsCore
import SwiftUI

/// The entire UI: a single popover hung off the menubar item. Signed-out shows
/// the GitHub connect flow; signed-in shows fleet config + the online toggle +
/// live runners. Kept in one view to avoid multi-window plumbing in the MVP.
struct MenuContentView: View {
  @EnvironmentObject private var app: AppState
  @State private var pat = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if let message = app.statusMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      if app.isSignedIn {
        fleetSection
      } else {
        connectSection
      }

      Divider()
      HStack(spacing: 12) {
        if app.isSignedIn {
          Button("Sign out", action: app.signOut)
            .buttonStyle(.link)
          if app.state == .offline {
            Button("Clean up", action: app.cleanUpHostFiles)
              .buttonStyle(.link)
              .help("Remove the cached runner agent and all per-run files from this Mac")
          }
        }
        Spacer()
        Button("Quit Mactions") { NSApp.terminate(nil) }
          .buttonStyle(.link)
      }
    }
    .padding(14)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      Circle().fill(statusColor).frame(width: 9, height: 9)
      Text("Mactions").font(.headline)
      Spacer()
      Text(app.state.rawValue.capitalized)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
  }

  private var statusColor: Color {
    switch app.state {
    case .offline: return .secondary
    case .starting, .stopping: return .orange
    case .online: return .green
    }
  }

  // MARK: Connect (signed out)

  private var connectSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Connect GitHub").font(.subheadline.weight(.semibold))

      if app.gitHubCLIAvailable {
        Button {
          app.signInWithGitHubCLI()
        } label: {
          Label("Use my GitHub CLI login", systemImage: "terminal")
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        Text("Easiest — reuses your existing `gh` login. No token needed.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("Other ways to connect").font(.caption).foregroundStyle(.secondary)
      }

      if let code = app.pendingDeviceCode {
        VStack(alignment: .leading, spacing: 6) {
          Text("Enter this code at github.com/login/device (opened in your browser):")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(code.userCode)
            .font(.system(.title2, design: .monospaced).weight(.bold))
            .textSelection(.enabled)
          ProgressView().controlSize(.small)
        }
      } else {
        Button {
          app.signInWithDeviceFlow()
        } label: {
          Label("Sign in with GitHub", systemImage: "person.badge.key")
        }
        .disabled(app.authBusy)

        Text("Device-flow sign-in needs an OAuth App client id (see below). No client id yet? Paste a token instead.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      LabeledField("OAuth client id (optional)", text: $app.clientId, prompt: "Iv1.xxxxxxxx")
        .onChange(of: app.clientId) { _ in app.saveConfig() }

      Divider()

      Text("…or paste a token").font(.caption).foregroundStyle(.secondary)
      SecureField("ghp_… / github_pat_…", text: $pat)
        .textFieldStyle(.roundedBorder)
      Button("Use token") {
        app.signInWithToken(pat)
        pat = ""
      }
      .disabled(pat.trimmingCharacters(in: .whitespaces).isEmpty)
      Text("Needs repo-admin (`repo` scope, or fine-grained Administration: read & write).")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Fleet (signed in)

  private var fleetSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      LabeledField("Owner", text: $app.owner, prompt: "Kyter-com")
        .disabled(app.state != .offline)
      LabeledField("Repo", text: $app.repo, prompt: "sweep-collector")
        .disabled(app.state != .offline)
      LabeledField("Labels", text: $app.labelsText, prompt: "self-hosted,macOS")
        .disabled(app.state != .offline)
      Stepper("Runners: \(app.desiredCount)", value: $app.desiredCount, in: 1...5)
        .disabled(app.state != .offline)

      Button {
        app.toggleOnline()
      } label: {
        Label(
          app.state == .offline ? "Go online" : "Go offline",
          systemImage: app.state == .offline ? "play.fill" : "stop.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .disabled(app.state == .starting || app.state == .stopping)

      if !app.runners.isEmpty {
        Text("Runners").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(app.runners) { runner in
          HStack(spacing: 6) {
            Image(systemName: "circle.fill")
              .font(.system(size: 6))
              .foregroundStyle(runner.phase == .online ? Color.green : Color.orange)
            Text(runner.id).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(runner.phase.rawValue).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

/// A label-over-field pair sized for the narrow popover.
private struct LabeledField: View {
  let title: String
  @Binding var text: String
  var prompt: String = ""

  init(_ title: String, text: Binding<String>, prompt: String = "") {
    self.title = title
    self._text = text
    self.prompt = prompt
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      TextField(prompt, text: $text).textFieldStyle(.roundedBorder)
    }
  }
}
