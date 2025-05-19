import SwiftUI
import RealityKit // for ARViewModel
import ARKit      // for ARViewModel

// Allow URL to work with .sheet(item:)
extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct FileBrowserView: View {
    @EnvironmentObject var arViewModel: ARViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var plyFiles: [URL] = []
    @State private var objFiles: [URL] = [] // Added for OBJ files
    @State private var loadErrorMessage: String?
    @State private var showErrorAlert = false
    @State private var currentSelection: URL?
    
    // For scan recovery
    @State private var inProgressScans: [ScanMetadata] = []
    @State private var selectedScan: ScanMetadata?
    @State private var showRecoveryAlert = false

    var body: some View {
        NavigationView {
            List {
                // In-progress scan recovery section
                if !inProgressScans.isEmpty {
                    Section(header: Text("Recovery").font(.headline)) {
                        ForEach(inProgressScans, id: \.scanId) { scanMetadata in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Interrupted Scan")
                                        .font(.headline)
                                    Text(formatScanDate(scanMetadata.creationDate))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Text("\(scanMetadata.frameCount) frames, \(scanMetadata.meshAnchorCount) anchors")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Button(action: {
                                    selectedScan = scanMetadata
                                    showRecoveryAlert = true
                                }) {
                                    Text("Recover")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                
                // Saved Point Clouds (.ply)
                if !plyFiles.isEmpty {
                    Section(header: Text("Saved Point Clouds (.ply)").font(.headline)) {
                        ForEach(plyFiles, id: \.self) { url in
                            HStack {
                                Button(action: { currentSelection = url }) {
                                    VStack(alignment: .leading) {
                                        Text(url.lastPathComponent)
                                            .font(.headline)
                                        Text(formattedDate(for: url))
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        
                                        if url.lastPathComponent.contains("Dense") {
                                            Text("Dense")
                                                .font(.caption)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.2))
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                                Spacer()
                                Button(action: { shareFile(url) }) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                        .onDelete(perform: deletePLYFiles)
                    }
                }

                // Saved Models (.obj)
                if !objFiles.isEmpty {
                    Section(header: Text("Saved Models (.obj)").font(.headline)) {
                        ForEach(objFiles, id: \.self) { url in
                            HStack {
                                Button(action: { currentSelection = url }) {
                                    VStack(alignment: .leading) {
                                        Text(url.lastPathComponent)
                                            .font(.headline)
                                        Text(formattedDate(for: url)) // Assuming same date formatting
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                                Spacer()
                                // Optionally, add a share button for OBJ files if needed
                                // Button(action: { shareFile(url) }) {
                                //     Image(systemName: "square.and.arrow.up")
                                // }
                            }
                        }
                        .onDelete(perform: deleteOBJFiles)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle()) // Or any other style you prefer
            .padding(.vertical, 4)
            .navigationTitle("Project Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reload") {
                        loadProjectFiles()
                    }
                }
            }
            .onAppear {
                loadProjectFiles()
                checkForInProgressScans()
                arViewModel.arView?.session.pause()
            }
            .onDisappear {
                if let config = arViewModel.arView?.session.configuration {
                    arViewModel.arView?.session.run(config)
                }
            }
            .sheet(item: $currentSelection) { url in
                if url.pathExtension.lowercased() == "ply" {
                    PointCloudView(plyURL: url)
                        .environmentObject(arViewModel)
                } else if url.pathExtension.lowercased() == "obj" {
                    // Placeholder for OBJSceneView - this will be created next
                    OBJSceneView(objURL: url) 
                         .environmentObject(arViewModel) // Pass arViewModel if OBJSceneView needs it
                } else {
                    Text("Unsupported file type: \(url.lastPathComponent)")
                }
            }
            .alert(isPresented: $showErrorAlert) {
                Alert(
                    title: Text("Error"),
                    message: Text(loadErrorMessage ?? "Unknown error"),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(isPresented: $showRecoveryAlert) {
                Alert(
                    title: Text("Recover Scan"),
                    message: Text("Would you like to recover this interrupted scan? This will continue from where you left off."),
                    primaryButton: .default(Text("Recover")) {
                        recoverScan()
                    },
                    secondaryButton: .cancel(Text("Discard")) {
                        selectedScan = nil
                    }
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle()) // Recommended for sheets
    }

    private func loadProjectFiles() {
        do {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let all = try FileManager.default.contentsOfDirectory(
                at: docsURL,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            // Sort by creation date, newest first
            let sortedFiles = all.sorted { (url1, url2) -> Bool in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 > date2
            }
            
            plyFiles = sortedFiles.filter { $0.pathExtension.lowercased() == "ply" }
            objFiles = sortedFiles.filter { $0.pathExtension.lowercased() == "obj" }
            
        } catch {
            loadErrorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
    
    private func checkForInProgressScans() {
        let storage = ScanStorage()
        inProgressScans = storage.findRecoverableScans()
    }
    
    private func recoverScan() {
        guard let scan = selectedScan else {
            return
        }
        
        presentationMode.wrappedValue.dismiss()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let storage = ScanStorage()
            let success = storage.recoverScan(withId: scan.scanId)
            if success {
                if let coordinator = arViewModel.coordinator {
                    coordinator.recoverScan(storage: storage, scanId: scan.scanId)
                    if let arView = arViewModel.arView, let config = arView.session.configuration {
                        arView.session.run(config, options: [.resetTracking])
                    }
                    arViewModel.scanStatus = .scanning
                }
            }
        }
    }
    
    private func formatScanDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formattedDate(for url: URL) -> String {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let creationDate = attributes[.creationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: creationDate)
        }
        return "Date N/A"
    }

    private func deletePLYFiles(at offsets: IndexSet) {
        let filesToDelete = offsets.map { plyFiles[$0] }
        for file in filesToDelete {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                print("Failed to delete PLY file \(file.lastPathComponent): \(error)")
            }
        }
        plyFiles.remove(atOffsets: offsets)
    }

    private func deleteOBJFiles(at offsets: IndexSet) {
        let filesToDelete = offsets.map { objFiles[$0] }
        for file in filesToDelete {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                print("Failed to delete OBJ file \(file.lastPathComponent): \(error)")
            }
        }
        objFiles.remove(atOffsets: offsets)
    }

    private func shareFile(_ url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        rootViewController.present(activityVC, animated: true, completion: nil)
    }
}

// Preview provider (optional, but good for development)
struct FileBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        FileBrowserView()
            .environmentObject(ARViewModel()) // Provide a mock ARViewModel
    }
}

