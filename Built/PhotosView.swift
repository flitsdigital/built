import SwiftUI
import SwiftData
import PhotosUI

// Progress foto's (PRD feature 7): maandelijks front/zij/rug, met automatische
// eerste-vs-laatste vergelijking per hoek. Foto's blijven lokaal (niet in Supabase).
struct PhotosView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PhotoEntry.date, order: .reverse) private var photos: [PhotoEntry]

    @State private var angle = "front"
    @State private var pickerItem: PhotosPickerItem?
    @State private var saveError: String?

    private let angles = [("front", "Voor"), ("side", "Zij"), ("back", "Rug")]
    private var filtered: [PhotoEntry] { photos.filter { $0.angle == angle } }

    var body: some View {
        List {
            Section {
                Picker("Hoek", selection: $angle) {
                    ForEach(angles, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }

            if let oldest = filtered.last, let newest = filtered.first, oldest.id != newest.id {
                Section("Vergelijk") {
                    HStack(spacing: 12) {
                        comparePhoto(oldest)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        comparePhoto(newest)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if filtered.isEmpty {
                    Text("Nog geen foto's voor deze hoek. Zelfde plek, zelfde licht, zelfde pose — dan zie je het verschil echt.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(filtered) { photo in
                        VStack(spacing: 4) {
                            thumbnail(photo)
                            Text(photo.date.formatted(.dateTime.day().month()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Verwijder foto", systemImage: "trash", role: .destructive) {
                                delete(photo)
                            }
                        }
                    }
                }
                .listRowSeparator(.hidden)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Foto toevoegen", systemImage: "plus")
                }
                if !photos.isEmpty {
                    ShareLink(items: photos.map(\.fileURL)) {
                        Label("Foto's exporteren", systemImage: "square.and.arrow.up")
                    }
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Alle foto's")
            } footer: {
                Text("Foto's blijven alleen op dit toestel — ze worden niet naar de server gesynct. Maak een back-up via Foto's exporteren of iCloud-toestelback-up.")
            }
        }
        .tabBarClearance()
        .navigationTitle("Progress foto's")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) {
            guard let pickerItem else { return }
            Task {
                if let data = try? await pickerItem.loadTransferable(type: Data.self) {
                    save(data)
                }
                self.pickerItem = nil
            }
        }
    }

    private func save(_ data: Data) {
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: PhotoEntry.directory.appendingPathComponent(name))
            context.insert(PhotoEntry(angle: angle, fileName: name))
            saveError = nil
        } catch {
            saveError = "Foto opslaan mislukt. Probeer het opnieuw."
        }
    }

    private func delete(_ photo: PhotoEntry) {
        try? FileManager.default.removeItem(at: photo.fileURL)
        context.delete(photo)
    }

    private func image(for photo: PhotoEntry) -> UIImage? {
        UIImage(contentsOfFile: photo.fileURL.path)
    }

    private func comparePhoto(_ photo: PhotoEntry) -> some View {
        VStack(spacing: 4) {
            if let ui = image(for: photo) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(photo.date.formatted(.dateTime.day().month().year()))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func thumbnail(_ photo: PhotoEntry) -> some View {
        Group {
            if let ui = image(for: photo) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.tertiarySystemFill)
            }
        }
        .frame(width: 100, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
