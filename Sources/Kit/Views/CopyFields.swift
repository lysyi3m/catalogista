import DiscogsKit
import SwiftUI

/// What belongs to this copy rather than the release: its folder, when it was added, and the
/// owner's custom fields in the order discogs.com shows them.
///
/// The folder and the added date lead, so they are always in the same place. Choices from a list,
/// such as Media Condition, follow them in the grid; free text comes after as paragraphs. Fields
/// left empty are not shown.
struct CopyFields<Folder: View>: View {
    let dateAdded: Date?
    let values: [FieldValue]
    let fields: [CustomField]
    @ViewBuilder let folder: Folder

    var body: some View {
        let filled = fields.compactMap { field -> (field: CustomField, value: String)? in
            guard let value = values.first(where: { $0.fieldID == field.id })?.value
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { return nil }
            return (field, value)
        }
        let added = dateAdded.map { [Fact(label: "Added", value: $0.formatted(date: .abbreviated, time: .omitted))] } ?? []
        let facts = added + filled.filter { !$0.field.isFreeText }.map { Fact(label: $0.field.name, value: $0.value) }
        PageSection("Copy") {
            VStack(alignment: .leading, spacing: 16) {
                FactGrid(entries: facts) {
                    FactCell(label: "Folder") { folder }
                }
                ForEach(filled.filter(\.field.isFreeText), id: \.field.id) { entry in
                    FactCell(label: entry.field.name) {
                        NotesText(notes: AttributedString(entry.value))
                    }
                }
            }
        }
    }
}
