import MactionsCore
import SwiftUI

/// The add-repository flow as a discrete commit/cancel sheet (the one place a
/// modal fits — picking which repos to manage is a deliberate task, unlike the
/// modeless per-combo tuning in the inspector). Toggling a repo adds it to the
/// plan (seeded with the default platforms) or removes it; "Done" dismisses.
struct AddRepoSheet: View {
  @EnvironmentObject private var app: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var filter = ""

  private var filtered: [RepoRef] {
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return app.availableRepos }
    return app.availableRepos.filter { $0.fullName.lowercased().contains(query) }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      searchBar
      Divider()
      list
      Divider()
      footer
    }
    .frame(width: 460, height: 540)
    .task { await app.loadReposIfNeeded() }
  }

  private var header: some View {
    HStack {
      Text(app.plan.isAllRepos ? "Repository Overrides" : "Manage Repositories").font(.headline)
      Spacer()
      Text(
        app.plan.isAllRepos
          ? "\(app.plan.repos.count) override\(app.plan.repos.count == 1 ? "" : "s")"
          : "\(app.plan.repos.count) configured"
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.card)
  }

  private var searchBar: some View {
    HStack(spacing: MactionsTheme.Spacing.tight) {
      Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
      TextField("Filter repositories…", text: $filter).textFieldStyle(.plain)
      if app.reposLoading {
        ProgressView().controlSize(.small)
      } else {
        Button {
          Task { await app.loadRepos() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh repositories")
        .accessibilityLabel("Refresh repositories")
      }
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.control)
  }

  @ViewBuilder
  private var list: some View {
    if app.reposLoading && app.availableRepos.isEmpty {
      // Distinguish "still fetching" from "genuinely none" — the bare list used
      // to render blank during the load, reading as an empty account.
      VStack(spacing: MactionsTheme.Spacing.control) {
        ProgressView()
        Text("Loading repositories…").font(.callout).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if app.availableRepos.isEmpty {
      DashboardEmptyState(
        systemImage: "tray", title: "No admin repos",
        message: "No repositories you can administer were found for this account. Try Refresh.")
    } else {
      List {
        ForEach(filtered) { repo in row(repo) }
      }
      .listStyle(.inset)
    }
  }

  private func row(_ repo: RepoRef) -> some View {
    Button {
      app.toggleRepo(repo)
    } label: {
      HStack(spacing: MactionsTheme.Spacing.control) {
        Image(systemName: app.isSelected(repo) ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(app.isSelected(repo) ? Color.accentColor : Color.secondary)
        Text(repo.fullName).font(.callout).lineLimit(1).truncationMode(.middle)
        if repo.isPrivate {
          Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(app.state != .offline)
  }

  private var footer: some View {
    HStack {
      if app.state != .offline {
        Label(MactionsTheme.Copy.offlineToManageRepos, systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
      if app.state == .offline, app.plan.isAllRepos {
        Text("Selected repositories use explicit overrides.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, MactionsTheme.Spacing.section)
    .padding(.vertical, MactionsTheme.Spacing.control)
  }
}
