import SwiftUI

struct SolPixelAvatarImage: View {
    let avatar: SolPixelAvatar
    let size: CGFloat

    var body: some View {
        Image(nsImage: SolPixelAvatarRenderer.shared.image(for: avatar))
            .interpolation(.none)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipped()
            .accessibilityHidden(true)
    }
}

struct SolPixelAvatarPicker: View {
    @Binding var selection: SolPixelAvatar

    @State private var style: SolPixelAvatarStyle
    @State private var batchSeed: UInt64

    private let columns = Array(
        repeating: GridItem(.fixed(52), spacing: 10),
        count: 6
    )

    init(selection: Binding<SolPixelAvatar>) {
        _selection = selection
        _style = State(initialValue: selection.wrappedValue.style)
        _batchSeed = State(initialValue: selection.wrappedValue.seed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Palette", selection: $style) {
                    ForEach(SolPixelAvatarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .frame(width: 170)

                Spacer()

                Button(action: shuffle) {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(candidates) { avatar in
                    avatarButton(avatar)
                }
            }

            Label(
                "Generated entirely on this Mac. Only the selected recipe is stored.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: style) { _, newStyle in
            selectFirstCandidate(for: newStyle)
        }
    }

    private var candidates: [SolPixelAvatar] {
        var generated = SolPixelAvatar.candidates(
            style: style,
            baseSeed: batchSeed
        )
        if selection.style == style,
           !generated.contains(selection) {
            generated.insert(selection, at: 0)
            generated = Array(generated.prefix(12))
        }
        return generated
    }

    private func avatarButton(_ avatar: SolPixelAvatar) -> some View {
        let isSelected = avatar == selection

        return Button {
            selection = avatar
        } label: {
            SolPixelAvatarImage(avatar: avatar, size: 48)
                .clipShape(Circle())
                .padding(2)
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? Color.accentColor : Color.clear,
                            lineWidth: 3
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.system(size: 17, weight: .semibold))
                            .background(.background, in: Circle())
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Use this \(avatar.style.title) pixel avatar")
        .accessibilityLabel("\(avatar.style.title) pixel avatar")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func shuffle() {
        batchSeed = UInt64.random(in: 0...UInt64(Int64.max))
        selectFirstCandidate(for: style)
    }

    private func selectFirstCandidate(for style: SolPixelAvatarStyle) {
        if let first = SolPixelAvatar.candidates(
            style: style,
            baseSeed: batchSeed,
            count: 1
        ).first {
            selection = first
        }
    }
}
