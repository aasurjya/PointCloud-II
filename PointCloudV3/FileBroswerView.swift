import SwiftUI
import RealityKit // for ARViewModel
import ARKit      // for ARViewModel

// Allow URL to work with .sheet(item:)
extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct FileBrowserView: View {
    @StateObject private var photogrammetryService = PhotogrammetryService() // Added for USDZ generation
    @State private var showPhotogrammetryProgressView = false // To show progress sheet
    @State private var photogrammetryInputProjectURL: URL? // To pass to the generation function
    @EnvironmentObject var arViewModel: ARViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var plyFiles: [URL] = []
    @State private var usdzFiles: [URL] = [] // Added for USDZ files
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
                                        
                                        // Display Photogrammetry Service status for this item if it's being processed
                                        if photogrammetryInputProjectURL == url && photogrammetryService.isProcessing {
                                            ProgressView(value: photogrammetryService.progress)
                                                .progressViewStyle(LinearProgressViewStyle())
                                            Text(String(format: "Processing USDZ: %.0f%%", photogrammetryService.progress * 100))
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        } else if let errorMsg = photogrammetryService.errorMessage, photogrammetryInputProjectURL == url {
                                            Text("Error: \(errorMsg)")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        }
                                        
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
                                
                                // Button to generate USDZ
                                if #available(iOS 17.0, *) {
                                    Button {
                                        self.photogrammetryInputProjectURL = url
                                        initiateUSDZGeneration(for: url)
                                    } label: {
                                        VStack {
                                            Image(systemName: "arkit")
                                            Text("USDZ")
                                                .font(.caption2)
                                        }
                                    }
                                    .disabled(photogrammetryService.isProcessing && photogrammetryInputProjectURL != url) // Disable if processing another or this one already
                                    .buttonStyle(BorderlessButtonStyle()) // Optional: for better tap feel in a list
                                    .padding(.leading, 5)
                                }
                            }
                        }
                        .onDelete(perform: deletePLYFiles)
                    }
                }

                // Saved Models (.obj)
                if !usdzFiles.isEmpty {
                    Section(header: Text("Saved Models (.usdz)").font(.headline)) {
                        ForEach(usdzFiles, id: \.self) { url in
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
                        .onDelete(perform: deleteUSDZFiles)
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
                } else if url.pathExtension.lowercased() == "usdz" {
                    // Placeholder for OBJSceneView - this will be created next
                    USDZViewer(usdzURL: url) // We will create USDZViewer next 
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
            .sheet(isPresented: $showPhotogrammetryProgressView) {
                if #available(iOS 17.0, *) {
                    PhotogrammetryProgressSheetView(projectToProcessURL: self.photogrammetryInputProjectURL)
                        .environmentObject(photogrammetryService)
                } else {
                    Text("USDZ generation requires iOS 17 or later.")
                }
            }
            .onChange(of: photogrammetryService.generatedModelURL) { newURL in
                if newURL != nil {
                    print("FileBrowserView: USDZ Generation complete, reloading project files.")
                    loadProjectFiles() // Refresh the list
                    photogrammetryInputProjectURL = nil // Reset target
                    // The sheet might handle its own dismissal or you can set showPhotogrammetryProgressView = false here
                }
            }
            .onChange(of: photogrammetryService.isProcessing) { processing in
                if !processing {
                    // If processing finishes (success or error), and the sheet is still up, 
                    // user can dismiss it. Or auto-dismiss on success after a delay.
                    // If there was an error, errorMessage will be set in service.
                    if photogrammetryService.generatedModelURL != nil { // Success
                        // showPhotogrammetryProgressView = false // Optional: auto-dismiss sheet
                    }
                }
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
            usdzFiles = sortedFiles.filter { $0.pathExtension.lowercased() == "usdz" }
            
        } catch {
            loadErrorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
    
    private func checkForInProgressScans() {
        let storage = ScanStorage()
        inProgressScans = storage.findRecoverableScans()
    }

    @available(iOS 17.0, *)
    private func initiateUSDZGeneration(for plyFileUrl: URL) {
        // Get the Documents directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // Debug: List all files in Documents directory
        print("📂 Contents of Documents directory:")
        var allContents: [URL] = []
        do {
            allContents = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for item in allContents {
                print(" - \(item.lastPathComponent)")
            }
        } catch {
            print("❌ Error listing Documents directory: \(error.localizedDescription)")
        }
        
        // Extract the scan ID from the PLY filename (e.g., "DensePointCloud_1747650115.ply" -> "1747650115")
        let plyName = plyFileUrl.deletingPathExtension().lastPathComponent
        let components = plyName.components(separatedBy: "_")
        guard components.count >= 2, let timestamp = components.last else {
            let errorMsg = "Invalid PLY filename format. Expected format: 'DensePointCloud_TIMESTAMP.ply'"
            print("❌ \(errorMsg)")
            showErrorAlert(message: errorMsg)
            return
        }
        
        print("🔍 Looking for scan directory with timestamp: \(timestamp)")
        
        // Look for any scan directory that might match our timestamp
        let fileManager = FileManager.default
        var foundScanDir: URL?
        
        // First try exact match
        let exactMatch = allContents.first { $0.lastPathComponent == "Scan_\(timestamp)" }
        
        if let exactMatch = exactMatch {
            foundScanDir = exactMatch
            print("✅ Found exact match scan directory: \(exactMatch.lastPathComponent)")
        } else {
            // If no exact match, try to find the closest matching scan directory
            print("ℹ️ No exact match found, searching for any scan directory...")
            
            // Get all scan directories
            let scanDirs = allContents.filter { $0.lastPathComponent.hasPrefix("Scan_") }
            
            if !scanDirs.isEmpty {
                print("🔍 Found the following scan directories:")
                for dir in scanDirs {
                    print(" - \(dir.lastPathComponent)")
                }
                
                // Sort by creation date (newest first)
                let sortedScans = scanDirs.sorted {
                    guard let date1 = try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate,
                          let date2 = try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                        return false
                    }
                    return date1 > date2
                }
                
                // Try to find a scan with a timestamp close to our PLY file
                if let mostRecentScan = sortedScans.first {
                    foundScanDir = mostRecentScan
                    print("ℹ️ Using most recent scan directory: \(mostRecentScan.lastPathComponent)")
                }
            }
        }
        
        guard let scanDirectory = foundScanDir else {
            let errorMsg = """
            Could not find a matching scan directory for PLY file: \(plyFileUrl.lastPathComponent)
            
            Make sure you have the corresponding 'Scan_TIMESTAMP' directory in your Documents folder.
            The PLY file should be generated from a scan that has its own directory with the frames.
            """
            print("❌ \(errorMsg)")
            showErrorAlert(message: errorMsg)
            return
        }
        
        print("🔍 Found scan directory: \(scanDirectory.path)")
        
        // Check for frames directory
        let framesDir = scanDirectory.appendingPathComponent("frames")
        var isDirectory: ObjCBool = false
        
        if fileManager.fileExists(atPath: framesDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
            print("✅ Found frames directory at: \(framesDir.path)")
            // List contents of frames directory
            do {
                let frameFiles = try fileManager.contentsOfDirectory(atPath: framesDir.path)
                print("📸 Found \(frameFiles.count) frame(s) in frames directory")
                if !frameFiles.isEmpty {
                    print("First few frames: \(frameFiles.prefix(5))")
                }
                
                // Check if we have enough frames
                if frameFiles.isEmpty {
                    let errorMsg = "The frames directory is empty. Cannot generate USDZ without any frames."
                    print("❌ \(errorMsg)")
                    showErrorAlert(message: errorMsg)
                    return
                }
                
                startPhotogrammetry(with: framesDir, plyFileUrl: plyFileUrl)
                
            } catch {
                let errorMsg = "Could not list contents of frames directory: \(error.localizedDescription)"
                print("❌ \(errorMsg)")
                showErrorAlert(message: errorMsg)
            }
        } else {
            // Try alternative directory name (case-sensitive)
            let alternativeFramesDir = scanDirectory.appendingPathComponent("Frames")
            if fileManager.fileExists(atPath: alternativeFramesDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                print("✅ Found Frames directory (capital F) at: \(alternativeFramesDir.path)")
                startPhotogrammetry(with: alternativeFramesDir, plyFileUrl: plyFileUrl)
            } else {
                let errorMsg = """
                Could not find 'frames' directory in scan folder.
                
                Looked in:
                - \(framesDir.path)
                - \(alternativeFramesDir.path)
                
                The scan directory exists but doesn't contain a 'frames' subdirectory with the captured images.
                Make sure you've completed a scan before trying to generate a USDZ.
                """
                print("❌ \(errorMsg)")
                showErrorAlert(message: errorMsg)
            }
        }
    }
    
    private func startPhotogrammetry(with imageDirectoryURL: URL, plyFileUrl: URL) {
        print("🔍 Starting photogrammetry with images from: \(imageDirectoryURL.path)")
        
        // Generate a unique output filename based on the PLY filename
        let baseName = plyFileUrl.deletingPathExtension().lastPathComponent
        let outputFileName = "\(baseName)_model"
        
        // Set the project URL so UI can reflect which item is being processed
        self.photogrammetryInputProjectURL = plyFileUrl
        
        // Log the directory contents for debugging
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: imageDirectoryURL.path)
            print("📋 Found \(contents.count) items in frames directory")
            print("📄 First few items: \(contents.prefix(5))")
        } catch {
            print("❌ Error listing frames directory: \(error.localizedDescription)")
        }
        
        // Using the simplified API
        photogrammetryService.generateUSDZ(from: imageDirectoryURL, outputFileName: outputFileName)
        showPhotogrammetryProgressView = true // Show the progress sheet
    }
    
    private func showErrorAlert(message: String) {
        // You can replace this with a proper alert in the UI
        print("❌ Error: \(message)")
        // For now, we'll just show an alert through the photogrammetry service
        photogrammetryService.errorMessage = message
        photogrammetryService.isProcessing = false
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

    private func deleteUSDZFiles(at offsets: IndexSet) {
        let filesToDelete = offsets.map { usdzFiles[$0] }
        for file in filesToDelete {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                print("Failed to delete OBJ file \(file.lastPathComponent): \(error)")
            }
        }
        usdzFiles.remove(atOffsets: offsets)
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
// MARK: - Photogrammetry Progress Sheet View
@available(iOS 17.0, *)
struct PhotogrammetryProgressSheetView: View {
    @EnvironmentObject var service: PhotogrammetryService
    let projectToProcessURL: URL? // Passed in directly
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if service.isProcessing {
                    Text("Generating USDZ Model...")
                        .font(.title2)
                    if let projectURL = projectToProcessURL {
                        Text(projectURL.deletingPathExtension().lastPathComponent)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    ProgressView(value: service.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .padding(.horizontal)
                    Text(String(format: "%.0f %%", service.progress * 100))
                    
                    Button("Cancel Processing") {
                        service.cancelProcessing()
                        // presentationMode.wrappedValue.dismiss() // Optionally dismiss immediately
                    }
                    .padding()
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                } else if let modelURL = service.generatedModelURL {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                    Text("Success!")
                        .font(.title2)
                        .foregroundColor(.green)
                    Text("USDZ model saved:")
                        .font(.headline)
                    Text(modelURL.lastPathComponent)
                        .font(.caption)
                        .padding(.bottom)
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .buttonStyle(.borderedProminent)

                } else if let errorMessage = service.errorMessage {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    Text("Error")
                        .font(.title2)
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Dismiss") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .buttonStyle(.bordered)
                } else {
                    // Fallback or initial state before processing starts from this sheet
                    Text("Ready to process.")
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .padding()
            .navigationTitle("USDZ Generation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !service.isProcessing { // Show close only if not actively processing, or after completion/error
                        Button("Close") {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(service.isProcessing) // Prevent swipe to dismiss while processing
    }
}

@available(iOS 17.0, *)
struct PhotogrammetryProgressSheetView_Previews: PreviewProvider {
    static var previews: some View {
        // Mock service for preview
        let mockService = PhotogrammetryService()
        // You can set properties on mockService here to test different states:
        // mockService.isProcessing = true
        // mockService.progress = 0.65
        // mockService.errorMessage = "Something went terribly wrong!"
        // mockService.generatedModelURL = URL(string: "file:///example.usdz")

        // Mock project URL for preview
        // let mockProjectURL = URL(string: "file:///dummyProject/scan.ply")

        return PhotogrammetryProgressSheetView(projectToProcessURL: nil /* mockProjectURL */)
            .environmentObject(mockService)
    }
}

// MARK: - Preview for FileBrowserView
struct FileBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        FileBrowserView()
            .environmentObject(ARViewModel()) // Provide a mock ARViewModel
    }
}

