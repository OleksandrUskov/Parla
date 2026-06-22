import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    private var text: String { item.display(timestamps: model.showTimestamps) }
    private var justCopied: Bool { model.lastCopiedID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.sourceName).font(.headline).lineLimit(1)
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.copyItem(item) } label: {
                    Label(justCopied ? "Скопировано" : "Копировать",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: text)
            }

            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var meta: String {
        let lang = item.language.isEmpty ? "?" : item.language.uppercased()
        return "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(lang) · \(prettyModel(item.model)) · \(Int(item.durationSec))s"
    }
}
