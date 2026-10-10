import DiscogsKit
import Foundation
import SwiftData

/// A custom field the owner defined on discogs.com, refreshed with every sync. The values live on
/// each copy (`CachedCollectionItem.fieldValues`); this holds what they are called and their order.
@Model
final class CachedField {
    @Attribute(.unique) var id: Int
    var name: String
    var position: Int
    var isFreeText: Bool

    init(from field: CustomField) {
        id = field.id
        name = field.name
        position = field.position
        isFreeText = field.isFreeText
    }

    var field: CustomField {
        CustomField(id: id, name: name, type: isFreeText ? "textarea" : "dropdown", position: position)
    }

    func update(from field: CustomField) {
        name = field.name
        position = field.position
        isFreeText = field.isFreeText
    }
}
