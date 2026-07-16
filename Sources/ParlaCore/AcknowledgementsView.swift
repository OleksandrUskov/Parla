import SwiftUI

/// In-app Acknowledgements / licenses screen (Settings → About). Cross-platform (macOS + iOS), presented as a sheet.
/// Lists the bundled third-party components + shows the full license texts. Data: `Acknowledgements`.
public struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("acknowledgements.intro"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Acknowledgements.components) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.headline)
                            Text("\(c.license) · \(c.copyright)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider().padding(.vertical, 4)

                    Text(Acknowledgements.licenseTexts)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(L("acknowledgements.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 560)
    }
}
