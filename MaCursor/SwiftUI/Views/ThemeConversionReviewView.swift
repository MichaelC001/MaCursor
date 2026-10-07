import SwiftUI

struct ThemeConversionReviewView: View {
    let outcome: ConversionOutcome
    let onConfirm: () -> Void
    let onConfirmAndEdit: () -> Void
    let onCancel: () -> Void

    private var allWarnings: [ImportWarning] {
        outcome.report.warnings + outcome.buildWarnings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.suggestedName).font(.headline)
                Text(String(format: NSLocalizedString("by %@", comment: "Theme creator attribution in the conversion review"),
                            outcome.suggestedCreator))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let previewURL = outcome.previewURL,
               let image = NSImage(contentsOf: previewURL) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxHeight: 96)
            }

            GroupBox(NSLocalizedString("Mapped", comment: "Mapped cursors group title")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(outcome.report.mapped.enumerated()), id: \.offset) { _, mapped in
                            HStack {
                                Text(mapped.displayName)
                                if mapped.isSecondary {
                                    Text(NSLocalizedString("2nd", comment: "Secondary mapping tag"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(mapped.identifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }

            if !outcome.report.ignored.isEmpty || !allWarnings.isEmpty {
                DisclosureGroup(String(format: NSLocalizedString("Warnings & ignored (%d)",
                                                                 comment: "Warnings and ignored group title with entry count"),
                                       allWarnings.count + outcome.report.ignored.count)) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(allWarnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning.description)
                                    .font(.caption)
                            }
                            ForEach(Array(outcome.report.ignored.enumerated()), id: \.offset) { _, ignored in
                                Text("\(ignored.source): \(ignored.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }

            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel, action: onCancel)
                Button(NSLocalizedString("Add & Edit…", comment: "Add to library then edit button"),
                       action: onConfirmAndEdit)
                Button(NSLocalizedString("Add to Library", comment: "Add to library button"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
