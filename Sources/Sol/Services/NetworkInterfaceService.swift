import Foundation
import SystemConfiguration

struct SolNetworkInterface: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String?

    static let automatic = SolNetworkInterface(
        id: "0",
        name: "Automatic",
        detail: "Let Sol Engine choose"
    )
}

enum NetworkInterfaceService {
    static func availableInterfaces() -> [SolNetworkInterface] {
        guard let systemInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [.automatic]
        }

        var seen = Set<String>()
        let interfaces = systemInterfaces.compactMap { interface -> SolNetworkInterface? in
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  bsdName != "lo0",
                  seen.insert(bsdName).inserted else {
                return nil
            }

            let displayName =
                SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                ?? bsdName
            return SolNetworkInterface(
                id: bsdName,
                name: displayName,
                detail: displayName == bsdName ? nil : bsdName
            )
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return [.automatic] + interfaces
    }
}
