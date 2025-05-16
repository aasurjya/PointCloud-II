//// FileBrowserView.swift
//// PointCloudV3
//// Created by ihub-devs on 13/05/25.
//
//import SwiftUI
//import RealityKit   // for ARViewModel
//import ARKit        // for ARViewModel
//
//// Allow URL to work with .sheet(item:)
//extension URL: Identifiable {
//    public var id: String { absoluteString }
//}
//
//struct FileBrowserView: View {
//    @EnvironmentObject var arViewModel: ARViewModel
//    @Environment(\.`presentationMode`) var presentationMode
//
//    @State private var plyFiles: [URL] = []
//    @State private var loadErrorMessage: String?
//    @State private var showErrorAlert = false
//    @State private var currentSelection: URL?
//
//    var body: some View {
//        NavigationView {
//            List(plyFiles, id: \.self) { url in
//                Button(action: { currentSelection = url }) {
//                    Text(url.lastPathComponent)
//                }
//            }
//            .navigationTitle("Saved PointClouds")
//            .toolbar {
//                Button("Reload", action: loadPLYFiles)
//            }
//            .onAppear(perform: loadPLYFiles)
//        }
//        // Pause AR session while browsing
//        .onAppear {
//            arViewModel.arView?.session.pause()
//        }
//        .onDisappear {
//            if let config = arViewModel.arView?.session.configuration {
//                arViewModel.arView?.session.run(config)
//            }
//        }
//        // Present the PointCloudView sheet when a file is tapped
//        .sheet(item: $currentSelection) { url in
//            PointCloudView(plyURL: url)
//                .environmentObject(arViewModel)
//        }
//        // Show an alert if directory scan fails
//        .alert(isPresented: $showErrorAlert) {
//            Alert(
//                title: Text("Error"),
//                message: Text(loadErrorMessage ?? "Unknown error"),
//                dismissButton: .default(Text("OK"))
//            )
//        }
//    }
//
//    private func loadPLYFiles() {
//        do {
//            let docsURL = FileManager.default
//                .urls(for: .documentDirectory, in: .userDomainMask)
//                .first!
//            let all = try FileManager.default.contentsOfDirectory(
//                at: docsURL,
//                includingPropertiesForKeys: nil,
//                options: [.skipsHiddenFiles]
//            )
//            plyFiles = all.filter { $0.pathExtension.lowercased() == "ply" }
//        } catch {
//            loadErrorMessage = error.localizedDescription
//            showErrorAlert = true
//        }
//    }
//}


// FileBrowserView.swift
// PointCloudV3
// Created by ihub-devs on 13/05/25.


import SwiftUI
import RealityKit
import ARKit

// Allow URL to work with .sheet(item:)
extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct FileBrowserView: View {
    @EnvironmentObject var arViewModel: ARViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var plyFiles: [URL] = []
    @State private var inProgressScans: [ScanMetadata] = []
    @State private var loadErrorMessage: String?
    @State private var showErrorAlert = false
    @State private var currentSelection: URL?
    @State private var showRecoveryAlert = false
    @State private var selectedScan: ScanMetadata?

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
                
                // Regular point clouds
                Section(header: Text("Point Clouds").font(.headline)) {
                    ForEach(plyFiles, id: \.self) { url in
                        HStack {
                            Button(action: { currentSelection = url }) {
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                        .font(.headline)
                                    Text(formattedDate(for: url))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    
                                    // Display dense point cloud badge if applicable
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
                    .onDelete(perform: deleteFiles)
                }
            }
            .padding(.vertical, 4)
            .navigationTitle("Saved PointClouds")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reload") {
                        loadPLYFiles()
                    }
                }
            }
            .onAppear(perform: loadPLYFiles)
            .onAppear(perform: checkForInProgressScans)
            .onAppear {
                arViewModel.arView?.session.pause()
            }
            .onDisappear {
                if let config = arViewModel.arView?.session.configuration {
                    arViewModel.arView?.session.run(config)
                }
            }
            .sheet(item: $currentSelection) { url in
                PointCloudView(plyURL: url)
                    .environmentObject(arViewModel)
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
                        // Optional: Delete the scan data
                        // deleteScan(selectedScan?.scanId)
                        selectedScan = nil
                    }
                )
            }
        }
    }

    private func loadPLYFiles() {
        do {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let all = try FileManager.default.contentsOfDirectory(
                at: docsURL,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
            plyFiles = all.filter { $0.pathExtension.lowercased() == "ply" }
                .sorted { (lhs, rhs) -> Bool in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    return lhsDate > rhsDate
                }
        } catch {
            loadErrorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
    
    /// Check for any in-progress scans that could be recovered
    private func checkForInProgressScans() {
        let storage = ScanStorage()
        inProgressScans = storage.findRecoverableScans()
    }
    
    /// Recover a previously interrupted scan
    private func recoverScan() {
        guard let scan = selectedScan else {
            return
        }
        
        presentationMode.wrappedValue.dismiss()
        
        // Create a small delay to ensure view is dismissed first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Create a new storage instance
            let storage = ScanStorage()
            let success = storage.recoverScan(withId: scan.scanId)
            
            if success {
                // Give the storage instance to the ARViewModel's coordinator
                if let coordinator = arViewModel.coordinator {
                    // Update the scan storage in the coordinator
                    coordinator.recoverScan(storage: storage, scanId: scan.scanId)
                    
                    // Reset tracking but keep scan data
                    if let arView = arViewModel.arView, let config = arView.session.configuration {
                        arView.session.run(config, options: [.resetTracking])
                    }
                    
                    // Update UI state
                    arViewModel.scanStatus = .scanning
                }
            }
        }
    }
    
    /// Format a date for display in the recovery UI
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
        return ""
    }

    private func deleteFiles(at offsets: IndexSet) {
        let filesToDelete = offsets.map { plyFiles[$0] }
        for file in filesToDelete {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                print("Failed to delete \(file.lastPathComponent): \(error)")
            }
        }
        plyFiles.remove(atOffsets: offsets)
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
