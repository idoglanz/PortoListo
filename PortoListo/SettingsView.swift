import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: PortMonitor
    @Environment(\.dismiss) var dismiss

    @State private var portInput = ""
    @State private var labelInput = ""
    @State private var errorMsg = ""
    @State private var editingPort: WatchedPort?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Configure Ports")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Watch individual ports or ranges like 3000-3005")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            if monitor.watchedPorts.isEmpty {
                emptyPortList
            } else {
                List {
                    ForEach(monitor.watchedPorts) { wp in
                        PortListRow(wp: wp, onEdit: {
                            editingPort = wp
                            portInput = wp.value
                            labelInput = wp.label
                        }, onDelete: {
                            monitor.removePort(withID: wp.id)
                        })
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(spacing: 10) {
                if !errorMsg.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Port / Range", systemImage: "number")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("3000  or  3000-3010", text: $portInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 150)
                            .onSubmit { addPort() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Label", systemImage: "tag")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("e.g. Frontend", text: $labelInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit { addPort() }
                    }

                    Button(action: addPort) {
                        HStack(spacing: 4) {
                            Image(systemName: editingPort != nil ? "checkmark.circle.fill" : "plus.circle.fill")
                            Text(editingPort != nil ? "Update" : "Add")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(portInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])

                    if editingPort != nil {
                        Button("Cancel") { resetForm() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: errorMsg)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 420)
    }

    // MARK: - Empty State

    private var emptyPortList: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(Color.secondary.opacity(0.4))
            Text("No ports yet -- add one below")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Add / Update Logic

    private func addPort() {
        let raw = portInput.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        if let validationError = WatchedPort.validate(raw) {
            errorMsg = validationError.errorDescription ?? "Invalid port"
            return
        }

        if let existing = monitor.watchedPorts.first(where: { $0.value == raw }),
           existing.id != editingPort?.id {
            errorMsg = "'\(raw)' is already in your list"
            return
        }

        let label = labelInput.trimmingCharacters(in: .whitespaces)

        if let editing = editingPort {
            monitor.updatePort(WatchedPort(id: editing.id, value: raw, label: label))
        } else {
            monitor.addPort(WatchedPort(value: raw, label: label))
        }

        resetForm()
    }

    private func resetForm() {
        editingPort = nil
        portInput = ""
        labelInput = ""
        errorMsg = ""
    }
}

// MARK: - Port List Row

struct PortListRow: View {
    let wp: WatchedPort
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(wp.label.isEmpty ? "Unlabeled" : wp.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(wp.label.isEmpty ? .secondary : .primary)

                HStack(spacing: 4) {
                    Text(":\(wp.value)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)

                    if wp.isRange {
                        Text("\u{00B7}")
                            .foregroundColor(Color.secondary.opacity(0.4))
                        Text("\(wp.ports.count) ports")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
            }
            Spacer()

            if isHovered {
                HStack(spacing: 6) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Edit port")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Delete port")
                }
                .transition(.opacity.combined(with: .scale))
            } else {
                Image(systemName: wp.isRange ? "ellipsis.rectangle" : "circle.dotted")
                    .font(.system(size: 12))
                    .foregroundColor(Color.secondary.opacity(0.4))
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
