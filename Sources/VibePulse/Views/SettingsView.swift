import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section("Data Sources") {
        Toggle("Claude Code", isOn: $model.includeClaude)
        Toggle("Codex", isOn: $model.includeCodex)
      }

      Section("Startup") {
        Toggle("Start at login", isOn: $model.startAtLogin)
        if let message = model.loginItemMessage {
          Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Section("Dependencies") {
        TextField("npx path (optional)", text: $model.npxPath)
        Text("Leave blank to auto-detect. Example: /opt/homebrew/bin/npx")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section {
        HStack {
          Picker("Update Frequency", selection: $model.refreshInterval) {
            ForEach(RefreshInterval.allCases) { interval in
              Text(interval.title).tag(interval)
            }
          }

          Spacer()

          Button("Refresh Now") {
            model.refreshNow()
          }
          .disabled(model.isRefreshing)
        }
      }

      Section {
        Picker("Data Maintenance", selection: $model.maintenanceMode) {
          ForEach(MaintenanceMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Text(model.maintenanceMode.detail)
          .font(.caption)
          .foregroundColor(.secondary)

        HStack {
          Button("Run Maintenance Now") {
            model.runMaintenance(force: true)
          }
          .disabled(model.isMaintaining)

          if let lastRun = model.lastMaintenanceAt {
            Text("Last run \(lastRun, format: .dateTime.hour().minute())")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }

        if let message = model.maintenanceMessage {
          Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Section("About") {
        Text(AppInfo.displayName)
          .font(.headline)
        Text("Version \(AppInfo.version)")
          .font(.caption)
          .foregroundColor(.secondary)
        Text("Git \(AppInfo.gitHash)")
          .font(.caption)
          .foregroundColor(.secondary)
        Text("Copyright (c) \(AppInfo.currentYear) Wes McKinney")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(20)
    .frame(width: 480)
  }
}
