// FileBrowserView.swift
// PointCloudV3
// Created by ihub-devs on 13/05/25.

import SwiftUI
import RealityKit   // for ARViewModel
import ARKit        // for ARViewModel

// Allow URL to work with .sheet(item:)
extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct FileBrowserView: View {
    @EnvironmentObject var arViewModel: ARViewModel
    @Environment(\.`presentationMode`) var presentationMode

    @State private var plyFiles: [URL] = []
    @State private var loadErrorMessage: String?
    @State private var showErrorAlert = false
    @State private var currentSelection: URL?

    var body: some View {
        NavigationView {
            List(plyFiles, id: \.self) { url in
                Button(action: { currentSelection = url }) {
                    Text(url.lastPathComponent)
                }
            }
            .navigationTitle("Saved PointClouds")
            .toolbar {
                Button("Reload", action: loadPLYFiles)
            }
            .onAppear(perform: loadPLYFiles)
        }
        // Pause AR session while browsing
        .onAppear {
            arViewModel.arView?.session.pause()
        }
        .onDisappear {
            if let config = arViewModel.arView?.session.configuration {
                arViewModel.arView?.session.run(config)
            }
        }
        // Present the PointCloudView sheet when a file is tapped
        .sheet(item: $currentSelection) { url in
            PointCloudView(plyURL: url)
                .environmentObject(arViewModel)
        }
        // Show an alert if directory scan fails
        .alert(isPresented: $showErrorAlert) {
            Alert(
                title: Text("Error"),
                message: Text(loadErrorMessage ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func loadPLYFiles() {
        do {
            let docsURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first!
            let all = try FileManager.default.contentsOfDirectory(
                at: docsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            plyFiles = all.filter { $0.pathExtension.lowercased() == "ply" }
        } catch {
            loadErrorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
}
