import AppKit
import SwiftUI

struct SetupCommandButton: View {
    static let command = #"""
    mkdir -p "$HOME/Library/Application Support/ClaudeMeter/CLI" && \
    cd "$HOME/Library/Application Support/ClaudeMeter/CLI" && \
    claude /usage
    """#

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(Self.command, forType: .string)
            } label: {
                Label(L10n.string(copied ? "action.setup_command_copied" : "action.copy_setup_command"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help(Self.command)
            Text(L10n.string("setup.paste_command_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { copied = false }
    }
}
