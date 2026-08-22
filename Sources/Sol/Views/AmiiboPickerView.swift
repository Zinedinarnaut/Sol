import SwiftUI

struct AmiiboPickerView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: [AmiiboCatalogItem] = []
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var showAll = false
    @State private var useRandomUUID = false
    @State private var isLoading = true
    @State private var loadError: String?

    private var activeTitleID: String? {
        viewModel.session.titleID ?? viewModel.selectedGame?.titleId
    }

    private var visibleItems: [AmiiboCatalogItem] {
        catalog.filter { item in
            let matchesCompatibility = showAll || item.isCompatible(with: activeTitleID)
            let matchesSearch = searchText.isEmpty ||
                item.name.localizedCaseInsensitiveContains(searchText) ||
                item.character.localizedCaseInsensitiveContains(searchText) ||
                item.amiiboSeries.localizedCaseInsensitiveContains(searchText)
            return matchesCompatibility && matchesSearch
        }
    }

    private var selectedItem: AmiiboCatalogItem? {
        guard let selectedID else { return nil }
        return catalog.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(18)

            Divider()

            Group {
                if isLoading {
                    ProgressView("Updating NFC figure catalog…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "NFC Figure Catalog Unavailable",
                        systemImage: "wave.3.right.slash",
                        description: Text(loadError)
                    )
                } else {
                    browser
                }
            }

            Divider()

            footer
                .padding(14)
        }
        .frame(minWidth: 720, minHeight: 540)
        .task {
            await loadCatalog()
        }
        .onChange(of: visibleItems.map(\.id)) { _, ids in
            if selectedID == nil || !ids.contains(selectedID ?? "") {
                selectedID = ids.first
            }
        }
        .onChange(of: viewModel.isAmiiboPickerPresented) { _, isPresented in
            if !isPresented {
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan NFC Figure")
                    .font(.title2.weight(.semibold))
                Text(viewModel.session.title ?? viewModel.selectedGame?.title ?? "Active game")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Toggle("Show All", isOn: $showAll)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var browser: some View {
        HSplitView {
            List(visibleItems, selection: $selectedID) { item in
                HStack(spacing: 12) {
                    amiiboImage(item, size: 54)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text("\(item.amiiboSeries) · \(item.type)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .tag(item.id)
            }
            .overlay {
                if visibleItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .frame(minWidth: 320)

            detail
                .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            VStack(spacing: 18) {
                Spacer(minLength: 12)
                amiiboImage(item, size: 190)

                VStack(spacing: 5) {
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                    Text(item.character)
                        .foregroundStyle(.secondary)
                    Text(item.gameSeries)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let activeTitleID, !activeTitleID.isEmpty {
                    Label(
                        item.isCompatible(with: activeTitleID)
                            ? "Listed as compatible with this game"
                            : "Compatibility is not listed for this game",
                        systemImage: item.isCompatible(with: activeTitleID)
                            ? "checkmark.circle.fill"
                            : "questionmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
            }
            .padding(24)
        } else {
            ContentUnavailableView(
                "Select an NFC Figure",
                systemImage: "wave.3.right.circle",
                description: Text("Choose an item from the catalog to scan it.")
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Use a new tag ID each scan", isOn: $useRandomUUID)
                .toggleStyle(.checkbox)

            if let message = viewModel.amiiboStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Cancel", role: .cancel) {
                viewModel.isAmiiboPickerPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Scan") {
                guard let selectedItem else { return }
                viewModel.scanAmiibo(
                    id: selectedItem.scanID,
                    useRandomUUID: useRandomUUID
                )
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedItem == nil || viewModel.isAmiiboScanPending)
        }
    }

    @ViewBuilder
    private func amiiboImage(_ item: AmiiboCatalogItem, size: CGFloat) -> some View {
        AsyncImage(url: item.imageURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
            case .empty:
                ProgressView()
                    .controlSize(.small)
            case .failure:
                Image(systemName: "wave.3.right.circle")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundStyle(.secondary)
            @unknown default:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: size * 0.16))
    }

    @MainActor
    private func loadCatalog() async {
        isLoading = true
        loadError = nil
        do {
            catalog = try await AmiiboCatalogService.shared.catalog()
            selectedID = visibleItems.first?.id
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
