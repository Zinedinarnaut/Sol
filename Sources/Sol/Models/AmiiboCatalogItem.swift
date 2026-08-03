import Foundation

struct AmiiboCatalogItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let scanID: String
    let name: String
    let character: String
    let gameSeries: String
    let amiiboSeries: String
    let type: String
    let imageURL: URL?
    let compatibleTitleIDs: Set<String>

    func isCompatible(with titleID: String?) -> Bool {
        guard let titleID = titleID?.uppercased(), !titleID.isEmpty else {
            return true
        }
        return compatibleTitleIDs.contains(titleID)
    }
}
