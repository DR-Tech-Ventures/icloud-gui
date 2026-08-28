import Photos
import SwiftUI

struct PhotoGrid: View {
    @ObservedObject var store: PhotoStore
    @Binding var thumbSize: Double

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(thumbSize),
                            maximum: CGFloat(thumbSize) * 1.5), spacing: 6)]
    }

    var body: some View {
        Group {
            if store.assets.isEmpty {
                switch store.selectedAlbum?.notice {
                case .hiddenLocked:
                    // Not our bug and not fixable in code: while the Hidden album
                    // requires authentication, macOS withholds those assets from
                    // every third-party app.
                    ContentUnavailableView {
                        Label("Hidden photos are locked", systemImage: "lock")
                    } description: {
                        Text("macOS does not release hidden photos to any other app while the Hidden album is protected — even with full Photos access.\n\nIn Photos, open Settings (⌘,) → General and turn off “Use Touch ID or Password”, then pick Reload Library and Rescan from the destination menu in the toolbar.")
                            .frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .recentlyDeleted:
                    ContentUnavailableView {
                        Label("Recently Deleted can't be read", systemImage: "trash.slash")
                    } description: {
                        Text("Apple's Photos framework has no Recently Deleted album, so no third-party app can reach it. This is a restriction in macOS, not a missing feature here.\n\nTo download these photos: open Photos, go to Recently Deleted, select what you want and click Recover. They return to your library and appear here after a rescan.")
                            .frame(maxWidth: 470)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .none:
                    ContentUnavailableView("No photos in this album",
                                           systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    // Sections stay lazy, so a library with thousands of day-groups
                    // only builds the headers and tiles actually on screen.
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.sections) { section in
                            Section {
                                LazyVGrid(columns: columns, spacing: 6) {
                                    ForEach(section.assets, id: \.localIdentifier) { asset in
                                        Thumbnail(asset: asset,
                                                  size: CGFloat(thumbSize),
                                                  isSelected: store.selection.contains(asset.localIdentifier),
                                                  store: store)
                                            .onTapGesture { store.toggle(asset) }
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, 10)
                                .padding(.bottom, 18)
                            } header: {
                                SectionHeader(section: section,
                                              allSelected: section.assets.allSatisfy {
                                                  store.selection.contains($0.localIdentifier)
                                              },
                                              toggle: { store.toggleSection(section) })
                            }
                        }
                    }
                }
            }
        }
    }

}

private struct SectionHeader: View {
    let section: AssetSection
    let allSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(section.title).font(.headline)
            Text("\(section.assets.count)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button(allSelected ? "Deselect" : "Select", action: toggle)
                .buttonStyle(.borderless).font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)      // keeps text legible while pinned over scrolling tiles
    }
}

private struct Thumbnail: View {
    let asset: PHAsset
    let size: CGFloat
    let isSelected: Bool
    let store: PhotoStore

    @State private var image: NSImage?

    var body: some View {
        // A flexible Color squared off with .fit is what pins the tile to its grid
        // cell. Sizing by .frame(height:) instead lets an aspectRatio(.fill) child
        // expand to the column width and overflow downward into the next section.
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))   // also clips the fill overflow
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(isSelected ? .palette : .monochrome)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(.white.opacity(0.85)),
                                     AnyShapeStyle(Color.accentColor))
                    .font(.system(size: 19)).shadow(radius: 1.5).padding(5)
            }
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video || asset.mediaSubtypes.contains(.photoLive) {
                    Image(systemName: asset.mediaType == .video ? "video.fill" : "livephoto")
                        .font(.caption).foregroundStyle(.white).shadow(radius: 1.5).padding(5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
            }
            .contentShape(Rectangle())
            .task(id: asset.localIdentifier) {
                image = await store.thumbnail(for: asset, size: size * 1.5)
            }
    }
}
