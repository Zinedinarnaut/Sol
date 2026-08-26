import SwiftUI
import WhatsNewKit

enum SolWhatsNew {
    static var current: WhatsNew {
        WhatsNew(
            title: "What’s New in Sol",
            features: [
                .init(
                    image: .init(systemName: "wand.and.stars", foregroundColor: .indigo),
                    title: "A proper first-run setup",
                    subtitle: "Connect your profile, review iCloud, install system files, and choose your library before entering Sol."
                ),
                .init(
                    image: .init(systemName: "person.badge.key.fill", foregroundColor: .blue),
                    title: "Safer Apple account storage",
                    subtitle: "Sol now keeps its account link in the protected Data Protection Keychain and can recover from older development builds."
                ),
                .init(
                    image: .init(systemName: "icloud.and.arrow.up.fill", foregroundColor: .cyan),
                    title: "Clearer Sol Cloud controls",
                    subtitle: "Choose automatic backup explicitly and see which portable profile data stays in iCloud—and which local files never leave your Mac."
                ),
            ],
            primaryAction: .init(title: "Continue to Sol")
        )
    }
}
