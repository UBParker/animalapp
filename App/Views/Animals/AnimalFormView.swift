import PhotosUI
import SwiftData
import SwiftUI

struct AnimalFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.selectedAnimalId) private var selectedAnimalId = ""
    @Query private var allAnimals: [Animal]

    let animal: Animal?

    @State private var name = ""
    @State private var species = ""
    @State private var colorHex = ColorPalette.defaultHex
    @State private var customColor = ColorPalette.color(ColorPalette.defaultHex)
    @State private var tracksOutdoorTime = true
    @State private var outdoorTouched = false
    @State private var note = ""
    @State private var pendingPhoto: Data?
    @State private var removePhoto = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !species.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Species", text: $species)
                    .onChange(of: species) { _, s in
                        if !outdoorTouched { tracksOutdoorTime = SpeciesDefaults.tracksOutdoorTime(s) }
                    }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SpeciesDefaults.suggestions, id: \.self) { s in
                            Button(s) { species = s }
                                .buttonStyle(.bordered)
                                .tint(species == s ? .accentColor : .secondary)
                        }
                    }
                }
            }
            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                    ForEach(ColorPalette.presets, id: \.self) { hex in
                        Circle().fill(ColorPalette.color(hex))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Color.primary, lineWidth: colorHex == hex ? 3 : 0))
                            .onTapGesture { colorHex = hex }
                            .accessibilityLabel(hex)
                    }
                }
                ColorPicker("Custom", selection: $customColor, supportsOpacity: false)
                    .onChange(of: customColor) { _, c in colorHex = ColorPalette.hex(c) }
            }
            Section("Photo") {
                HStack(spacing: 16) {
                    photoPreview
                    VStack(alignment: .leading) {
                        PhotosPicker("From library", selection: $pickerItem, matching: .images)
                        Button("Take photo") { showCamera = true }
                        if pendingPhoto != nil || (animal?.photoFilename != nil && !removePhoto) {
                            Button("Remove photo", role: .destructive) { pendingPhoto = nil; removePhoto = true }
                        }
                    }
                }
            }
            Section("Details") {
                Toggle("Tracks outdoor time", isOn: $tracksOutdoorTime)
                    .onChange(of: tracksOutdoorTime) { _, _ in outdoorTouched = true }
                TextField("Note", text: $note, axis: .vertical)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(animal == nil ? "Add Animal" : "Edit Animal")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .onAppear(perform: load)
        .onChange(of: pickerItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { pendingPhoto = data; removePhoto = false }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraCaptureView(mode: .photo, onPhoto: { data in pendingPhoto = data; removePhoto = false })
        }
    }

    @ViewBuilder
    private var photoPreview: some View {
        if let pendingPhoto, let image = UIImage(data: pendingPhoto) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(Circle())
        } else if let animal, !removePhoto, let thumb = animal.photoThumbnailFilename,
                  let image = UIImage(contentsOfFile: mediaStore.url(for: thumb).path) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(Circle())
        } else {
            Circle().fill(ColorPalette.color(colorHex)).frame(width: 72, height: 72)
                .overlay(Text(String(name.prefix(1)).uppercased()).font(.title).foregroundStyle(ColorPalette.contrastingText(on: colorHex)))
        }
    }

    private func load() {
        guard let animal else { return }
        name = animal.name
        species = animal.species
        colorHex = animal.colorHex
        customColor = ColorPalette.color(animal.colorHex)
        tracksOutdoorTime = animal.tracksOutdoorTime
        outdoorTouched = true
        note = animal.note ?? ""
    }

    private func save() {
        let target = animal ?? Animal(name: name, species: species, sortOrder: (allAnimals.map(\.sortOrder).max() ?? -1) + 1)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.species = species.trimmingCharacters(in: .whitespaces)
        target.colorHex = colorHex
        target.tracksOutdoorTime = tracksOutdoorTime
        target.note = note.isEmpty ? nil : note
        do {
            if removePhoto || pendingPhoto != nil {
                if let old = target.photoFilename { mediaStore.delete(old) }
                if let oldThumb = target.photoThumbnailFilename { mediaStore.delete(oldThumb) }
                target.photoFilename = nil
                target.photoThumbnailFilename = nil
            }
            if let pendingPhoto {
                let saved = try mediaStore.savePhoto(pendingPhoto)
                target.photoFilename = saved.filename
                target.photoThumbnailFilename = saved.thumbnailFilename
            }
            if animal == nil { context.insert(target) }
            try context.save()
            if selectedAnimalId.isEmpty { selectedAnimalId = target.id.uuidString }
            dismiss()
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
