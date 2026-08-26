import SwiftUI

struct ProfileActivityView: View {
    @ObservedObject var library: SolPlayActivityLibrary
    let games: [Game]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if library.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Detailed Activity Yet", systemImage: "waveform.path.ecg")
                } description: {
                    Text("When a game publishes local play reports, Sol will keep a private activity timeline here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(groupedEntries, id: \.day) { group in
                    Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.entries) { entry in
                            activityRow(entry)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: library.reload)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Play Activity")
                    .font(.largeTitle.weight(.semibold))
                Text("Private events reported by games and stored with your Sol profile.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                library.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
    }

    private func activityRow(_ entry: SolPlayActivityEntry) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "gamecontroller.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.activityTitle)
                    .font(.headline)
                Text(gameTitle(for: entry.titleID))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.date, style: .time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private var groupedEntries: [(day: Date, entries: [SolPlayActivityEntry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: library.entries) {
            calendar.startOfDay(for: $0.date)
        }
        .map { (day: $0.key, entries: $0.value) }
        .sorted { $0.day > $1.day }
    }

    private func gameTitle(for titleID: String) -> String {
        games.first {
            $0.titleId?.localizedCaseInsensitiveCompare(titleID) == .orderedSame
        }?.title ?? titleID
    }
}
