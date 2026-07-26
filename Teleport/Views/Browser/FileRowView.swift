import SwiftUI
import TeleportKit

/// The Name-column cell of the file Table: icon + filename (or an inline rename
/// field). Selection, activation, and drag are all handled by the Table /
/// `TableRow` and the keyboard — this cell deliberately carries no tap gesture,
/// because any tap gesture on a List/Table row intercepts the mouse-down and
/// suppresses the framework's click-to-select.
struct FileNameCell: View {
    let item: FileItem
    @Bindable var vm: BrowserViewModel

    /// Passed in rather than read from the environment on purpose. Table cells
    /// are hosted individually on macOS and a lazily re-realized cell can come
    /// up with an empty environment, so `@Environment(AppState.self)` here would
    /// resolve to nil and trap on every body update. Don't convert this back.
    let appState: AppState

    @FocusState private var renameFieldFocused: Bool

    private var isRenaming: Bool { vm.renamingItem?.id == item.id }

    var body: some View {
        if isRenaming {
            renameField
        } else {
            nameLabel
        }
    }

    private var icon: some View {
        Image(systemName: item.systemImage)
            .foregroundStyle(iconColor)
            .opacity(item.isHidden ? 0.55 : 1)
            .frame(width: 20, alignment: .center)
            .imageScale(.medium)
    }

    private var renameField: some View {
        HStack(spacing: 8) {
            icon
            TextField("Name", text: $vm.renameText)
                .textFieldStyle(.roundedBorder)
                .focused($renameFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { vm.renamingItem = nil }
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused && vm.renamingItem?.id == item.id {
                        commitRename()
                    }
                }
                .onAppear {
                    vm.renameText = item.name
                    renameFieldFocused = true
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nameLabel: some View {
        HStack(spacing: 8) {
            icon
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.isHidden ? Color.secondary : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconColor: Color {
        switch item.imageColor {
        case "blue":   return .blue
        case "purple": return .purple
        case "red":    return .red
        case "pink":   return .pink
        case "green":  return .green
        case "orange": return .orange
        default:       return .secondary
        }
    }

    private func commitRename() {
        let newName = vm.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else {
            vm.renamingItem = nil
            return
        }
        Task {
            do { try await vm.rename(item: item, to: newName) }
            catch { appState.showError(error) }   // e.g. name taken, permission denied
            vm.renamingItem = nil
        }
    }
}
