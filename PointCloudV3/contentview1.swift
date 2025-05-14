//
//  contentview1.swift
//  PointCloudV3
//
//  Created by ihub-devs on 14/05/25.
//


//app running in 30 Fps

// ContentView.swift
// PointCloudV3
// Updated: Merge raw mesh + depth capture + fixed unwrapping + cleaned up errors
//
//import SwiftUI
//import RealityKit
//import ARKit
//import SceneKit
//
//// MARK: â€“ View Model
//
//class ARViewModel: ObservableObject {
//    @Published var arView: ARView?
//}
//
//// MARK: â€“ ContentView
//
//struct ContentView: View {
//    @StateObject private var arViewModel = ARViewModel()
//    @State private var isSaving    = false
//    @State private var showBrowser = false
//
//    var body: some View {
//        ZStack {
//            ARViewContainer()
//                .edgesIgnoringSafeArea(.all)
//                .environmentObject(arViewModel)
//
//            VStack {
//                Spacer()
//
//                // Save combined mesh + depth point cloud
//                Button(action: saveMesh) {
//                    Text(isSaving ? "Saving..." : "Save Mesh")
//                        .padding()
//                        .background(isSaving ? Color.gray : Color.blue)
//                        .foregroundColor(.white)
//                        .cornerRadius(10)
//                }
//                .padding()
//                .disabled(isSaving)
//
//                // Browse existing exports
//                Button(action: { showBrowser.toggle() }) {
//                    Text("Browse Meshes")
//                        .padding()
//                        .background(Color.green)
//                        .foregroundColor(.white)
//                        .cornerRadius(10)
//                }
//                .padding(.bottom)
//            }
//            .sheet(isPresented: $showBrowser) {
//                FileBrowserView()
//                    .environmentObject(arViewModel)
//            }
//        }
//    }
//
//    private func saveMesh() {
//        isSaving = true
//        guard let arView = arViewModel.arView,
//              let coordinator = arView.session.delegate as? ARSessionDelegateCoordinator
//        else {
//            print("ARView or coordinator not found.")
//            isSaving = false
//            return
//        }
//
//        DispatchQueue.global(qos: .userInitiated).async {
//            coordinator.exportPointCloud()
//            DispatchQueue.main.async {
//                isSaving = false
//            }
//        }
//    }
//}
//
//// MARK: â€“ ARViewContainer with Depth Semantics
//
//struct ARViewContainer: UIViewRepresentable {
//    @EnvironmentObject var arViewModel: ARViewModel
//
//    func makeUIView(context: Context) -> ARView {
//        let arView = ARView(frame: .zero)
//
//        // 1ï¸âƒ£ Raw mesh (no classification)
//        let config = ARWorldTrackingConfiguration()
//        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
//            config.sceneReconstruction = .mesh
//        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
//            config.sceneReconstruction = .meshWithClassification
//        }
//
//        // 2ï¸âƒ£ Enable per-frame depth
//        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
//            config.frameSemantics.insert(.smoothedSceneDepth)
//        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
//            config.frameSemantics.insert(.sceneDepth)
//        }
//
//        arView.session.run(config)
//        arView.debugOptions = [.showSceneUnderstanding, .showFeaturePoints]
//
//        arView.session.delegate   = context.coordinator
//        arViewModel.arView        = arView
//        return arView
//    }
//
//    func updateUIView(_ uiView: ARView, context: Context) { /* no-op */ }
//
//    func makeCoordinator() -> ARSessionDelegateCoordinator {
//        ARSessionDelegateCoordinator()
//    }
//}
//
//// MARK: â€“ Coordinator: Collect Mesh + Depth Points
//
//class ARSessionDelegateCoordinator: NSObject, ARSessionDelegate {
//    var meshAnchors = [ARMeshAnchor]()
//    var depthPoints = [SIMD3<Float>]()
//
//    // Collect new or updated mesh anchors
//    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
//        updateMeshAnchors(with: anchors)
//    }
//    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
//        updateMeshAnchors(with: anchors)
//    }
//    private func updateMeshAnchors(with anchors: [ARAnchor]) {
//        for anchor in anchors {
//            if let m = anchor as? ARMeshAnchor,
//               !meshAnchors.contains(where: { $0.identifier == m.identifier }) {
//                meshAnchors.append(m)
//            }
//        }
//    }
//
//    // Capture per-frame depth points
//    func session(_ session: ARSession, didUpdate frame: ARFrame) {
//        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
//        let depthMap      = depthData.depthMap                // CVPixelBuffer
//        guard let confMap = depthData.confidenceMap           // CVPixelBuffer?
//        else { return }
//
//        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
//        CVPixelBufferLockBaseAddress(confMap, .readOnly)
//
//        let width       = CVPixelBufferGetWidth(depthMap)
//        let height      = CVPixelBufferGetHeight(depthMap)
//        let depthPtr    = unsafeBitCast(CVPixelBufferGetBaseAddress(depthMap),
//                                        to: UnsafePointer<Float32>.self)
//        let confPtr     = unsafeBitCast(CVPixelBufferGetBaseAddress(confMap),
//                                        to: UnsafePointer<UInt8>.self)
//
//        // Inverse intrinsics & camera transform
//        let intrinsicsInv = simd_inverse(frame.camera.intrinsics)
//        let camTransform  = frame.camera.transform
//
//        for y in 0..<height {
//            for x in 0..<width {
//                let idx = y * width + x
//                let d   = depthPtr[idx]
//                guard d > 0 else { continue }
//
//                let rawConf = confPtr[idx]
//                let level   = ARConfidenceLevel(rawValue: Int(rawConf)) ?? .low
//                guard level == .high else { continue }
//
//                // Unproject to camera-space
//                let uv1    = SIMD3<Float>(Float(x), Float(y), 1)
//                let xyzCam = intrinsicsInv * uv1 * d
//
//                // â†’ world-space
//                let world4     = camTransform * SIMD4<Float>(xyzCam, 1)
//                let worldPoint = SIMD3<Float>(world4.x, world4.y, world4.z)
//                depthPoints.append(worldPoint)
//            }
//        }
//
//        CVPixelBufferUnlockBaseAddress(confMap, .readOnly)
//        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
//    }
//
//    /// Export both meshâ€anchor vertices AND depthMap points to a single PLY.
//    func exportPointCloud() {
//        guard !meshAnchors.isEmpty || !depthPoints.isEmpty else {
//            print("Nothing to export.")
//            return
//        }
//
//        var allPoints = [SIMD3<Float>]()
//
//        // A) Mesh-anchors
//        for meshAnchor in meshAnchors {
//            let geo    = meshAnchor.geometry
//            let vb     = geo.vertices.buffer.contents()
//            let stride = geo.vertices.stride
//            let offset = geo.vertices.offset
//            for i in 0..<geo.vertices.count {
//                let ptr = vb.advanced(by: offset + i * stride)
//                var v = SIMD3<Float>()
//                memcpy(&v, ptr, MemoryLayout<SIMD3<Float>>.size)
//                let w4 = meshAnchor.transform * SIMD4<Float>(v, 1)
//                let wp = SIMD3<Float>(w4.x, w4.y, w4.z)
//                allPoints.append(wp)
//            }
//        }
//
//        // B) Depthâ€map points
//        allPoints.append(contentsOf: depthPoints)
//
//        // Build PLY header
//        var ply  = "ply\nformat ascii 1.0\n"
//        ply += "element vertex \(allPoints.count)\n"
//        ply += """
//               property float x
//               property float y
//               property float z
//               end_header
//               """
//        // Append vertices
//        ply += allPoints.map { "\($0.x) \($0.y) \($0.z)" }
//                         .joined(separator: "\n")
//
//        // Write to disk
//        let docs = FileManager.default
//                     .urls(for: .documentDirectory, in: .userDomainMask)[0]
//        let url  = docs.appendingPathComponent("PointCloud.ply")
//        do {
//            try ply.write(to: url, atomically: true, encoding: .utf8)
//            print("Saved PLY at \(url)")
//        } catch {
//            print("Failed to save PLY:", error)
//        }
//
//        // Reset for next capture
//        depthPoints.removeAll()
//    }
//}
//
