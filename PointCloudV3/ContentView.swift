// ContentView.swift
// PointCloudV3
// Updated for high-accuracy mesh reconstruction with colorful point cloud, fixing ARKit errors

import SwiftUI
import RealityKit
import ARKit
import CoreImage
import AVFoundation
import simd

// MARK: - View Model
class ARViewModel: ObservableObject {
    @Published var arView: ARView?
    var coordinator: ARSessionDelegateCoordinator?
    @Published var scanStatus: ScanStatus = .idle
    @Published var progressMessage: String = ""
    
    enum ScanStatus {
        case idle
        case scanning
        case processing
        case completed
        case error
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var arViewModel = ARViewModel()
    @State private var showBrowser = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var scanningTimer: Int = 0
    @State private var timerRunning = false
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ARViewContainer()
                .edgesIgnoringSafeArea(.all)
                .environmentObject(arViewModel)

            VStack {
                Spacer()
                
                if arViewModel.scanStatus == .idle {
                    Button(action: startScanning) {
                        Text("Start Scanning")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding()
                } else if arViewModel.scanStatus == .scanning {
                    VStack {
                        Text("Scanning: \(scanningTimer)s")
                            .font(.headline)
                            .padding()
                            .onReceive(timer) { _ in
                                if timerRunning {
                                    scanningTimer += 1
                                }
                            }
                        
                        Button(action: finishScanning) {
                            Text("Finish & Process Scan")
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .padding(.bottom, 8)
                        
                        Button(action: cancelScanning) {
                            Text("Cancel")
                                .padding()
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                } else if arViewModel.scanStatus == .processing {
                    VStack {
                        ProgressView()
                            .padding()
                        Text(arViewModel.progressMessage)
                            .padding()
                    }
                } else if arViewModel.scanStatus == .completed {
                    VStack {
                        Text("Scan Complete!")
                            .font(.headline)
                            .padding()
                        
                        Button(action: {
                            arViewModel.scanStatus = .idle
                            scanningTimer = 0
                        }) {
                            Text("New Scan")
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .padding(.bottom, 8)
                        
                        Button(action: { showBrowser.toggle() }) {
                            Text("Browse Meshes")
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showBrowser) {
            FileBrowserView()
                .environmentObject(arViewModel)
        }
        .alert(isPresented: $showError) {
            Alert(
                title: Text("Error"),
                message: Text(errorMessage ?? "Unknown error"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func startScanning() {
        // Lock exposure for consistent lighting
        if let device = AVCaptureDevice.default(for: .video) {
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                device.unlockForConfiguration()
            } catch {
                print("Failed to lock exposure: \(error)")
            }
        }
        
        // Reset and start fresh
        arViewModel.coordinator?.clearAnchors()
        arViewModel.coordinator?.clearFrames()
        arViewModel.scanStatus = .scanning
        scanningTimer = 0
        timerRunning = true
        
        // Start collecting textures
        arViewModel.coordinator?.startCollectingFrames()
    }
    
    private func cancelScanning() {
        // Unlock exposure
        if let device = AVCaptureDevice.default(for: .video) {
            do {
                try device.lockForConfiguration()
                device.exposureMode = .continuousAutoExposure
                device.unlockForConfiguration()
            } catch {
                print("Failed to unlock exposure: \(error)")
            }
        }
        
        arViewModel.scanStatus = .idle
        timerRunning = false
        scanningTimer = 0
        arViewModel.coordinator?.clearAnchors()
        arViewModel.coordinator?.clearFrames()
    }

    private func finishScanning() {
        guard let arView = arViewModel.arView,
              let coord = arViewModel.coordinator else {
            errorMessage = "ARView/session not ready"
            showError = true
            return
        }
        
        // Unlock exposure
        if let device = AVCaptureDevice.default(for: .video) {
            do {
                try device.lockForConfiguration()
                device.exposureMode = .continuousAutoExposure
                device.unlockForConfiguration()
            } catch {
                print("Failed to unlock exposure: \(error)")
            }
        }
        
        // Stop frame collection
        coord.stopCollectingFrames()
        timerRunning = false
        arViewModel.scanStatus = .processing
        arViewModel.progressMessage = "Processing scan data..."

        Task {
            // Make sure we have anchors and frames
            guard !coord.meshAnchors.isEmpty || !coord.planeAnchors.isEmpty else {
                await MainActor.run {
                    errorMessage = "No mesh data captured. Try scanning longer."
                    showError = true
                    arViewModel.scanStatus = .idle
                }
                return
            }
            
            guard !coord.capturedFrames.isEmpty else {
                await MainActor.run {
                    errorMessage = "No camera frames captured. Try scanning longer."
                    showError = true
                    arViewModel.scanStatus = .idle
                }
                return
            }

            // Pause session to freeze mesh
            await MainActor.run {
                arView.session.pause()
                arViewModel.progressMessage = "Exporting textured mesh..."
            }

            // Process the collected frames and mesh
            coord.exportMultiTexturedMesh()
            
            // Resume session for next scan
            await MainActor.run {
                if let config = arView.session.configuration {
                    arView.session.run(config)
                }
                arViewModel.scanStatus = .completed
            }
        }
    }
}

// MARK: - ARView Container
struct ARViewContainer: UIViewRepresentable {
    @EnvironmentObject var arViewModel: ARViewModel

    func makeCoordinator() -> ARSessionDelegateCoordinator {
        let coord = ARSessionDelegateCoordinator()
        arViewModel.coordinator = coord
        return coord
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        var config = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        
        // Optimize for high-quality textures
        config.wantsHDREnvironmentTextures = true
        config.isLightEstimationEnabled = true

        arView.session.run(config)
        arView.debugOptions = [.showSceneUnderstanding]

        arView.session.delegate = context.coordinator
        arViewModel.arView = arView
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Captured Frame
struct CapturedFrame {
    let image: CGImage
    let camera: ARCamera
    let timestamp: TimeInterval
    let transform: simd_float4x4
    
    var debugName: String {
        return "Frame_\(Int(timestamp * 1000))"
    }
}

// MARK: - AR Session Delegate
class ARSessionDelegateCoordinator: NSObject, ARSessionDelegate {
    var meshAnchors = [ARMeshAnchor]()
    var planeAnchors = [ARPlaneAnchor]()
    var capturedFrames = [CapturedFrame]()
    private var collectingFrames = false
    private var frameCollectionTimer: Timer?
    private let frameInterval: TimeInterval = 0.3 // Faster frame capture
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    func clearAnchors() {
        meshAnchors.removeAll()
        planeAnchors.removeAll()
    }
    
    func clearFrames() {
        capturedFrames.removeAll()
    }
    
    func startCollectingFrames() {
        collectingFrames = true
        frameCollectionTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            self?.captureCurrentFrame()
        }
    }
    
    func stopCollectingFrames() {
        collectingFrames = false
        frameCollectionTimer?.invalidate()
        frameCollectionTimer = nil
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if collectingFrames {
            captureCurrentFrame(frame: frame)
        }
    }
    
    private func captureCurrentFrame(frame: ARFrame? = nil) {
        guard collectingFrames,
              let frame = frame else { return }
        
        // Convert YCbCr to RGB
        let pixelBuffer = frame.capturedImage
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorImage = ciContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            print("❌ Failed to convert camera image to RGB")
            return
        }
        
        // Store frame with camera transform
        let capturedFrame = CapturedFrame(
            image: colorImage,
            camera: frame.camera,
            timestamp: frame.timestamp,
            transform: frame.camera.transform
        )
        
        // Limit stored frames to avoid memory issues
        if capturedFrames.count > 100 {
            capturedFrames.removeFirst()
        }
        capturedFrames.append(capturedFrame)
        print("📸 Captured frame \(capturedFrames.count): \(colorImage.width)x\(colorImage.height)")
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let m = anchor as? ARMeshAnchor { meshAnchors.append(m) }
            else if let p = anchor as? ARPlaneAnchor { planeAnchors.append(p) }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let m = anchor as? ARMeshAnchor,
               let i = meshAnchors.firstIndex(where: { $0.identifier == m.identifier }) {
                meshAnchors[i] = m
            } else if let p = anchor as? ARPlaneAnchor,
                      let i = planeAnchors.firstIndex(where: { $0.identifier == p.identifier }) {
                planeAnchors[i] = p
            }
        }
    }
    
    private func bestFrameForPoint(_ point: SIMD3<Float>, normal: SIMD3<Float>?) -> CapturedFrame? {
        guard !capturedFrames.isEmpty else { return nil }
        
        if capturedFrames.count == 1 {
            return capturedFrames.first
        }
        
        var bestScore: Float = -Float.greatestFiniteMagnitude
        var bestFrame: CapturedFrame?
        
        for frame in capturedFrames {
            let cameraPosition = SIMD3<Float>(frame.transform.columns.3.x,
                                              frame.transform.columns.3.y,
                                              frame.transform.columns.3.z)
            let toCamera = normalize(cameraPosition - point)
            var score: Float = 1.0 / (length(cameraPosition - point) + 0.1)
            
            if let normal = normal {
                let alignment = dot(toCamera, normalize(normal))
                score *= max(0.3, alignment)
            }
            
            let projectedPoint = frame.camera.projectPoint(point,
                                                           orientation: .portrait,
                                                           viewportSize: CGSize(width: CGFloat(frame.image.height),
                                                                                height: CGFloat(frame.image.width)))
            
            if projectedPoint.x < 0 || projectedPoint.y < 0 ||
                projectedPoint.x > CGFloat(frame.image.height) || projectedPoint.y > CGFloat(frame.image.width) {
                score *= 0.1
            }
            
            if score > bestScore {
                bestScore = score
                bestFrame = frame
            }
        }
        
        return bestFrame ?? capturedFrames.last
    }
    
    //    private func sampleColor(worldPoint: SIMD3<Float>, frame: CapturedFrame) -> SIMD3<UInt8> {
    //        let cam = frame.camera
    //        let projSize = CGSize(width: cam.imageResolution.height,
    //                             height: cam.imageResolution.width)
    //
    //        let proj = cam.projectPoint(worldPoint,
    //                                   orientation: .portrait,
    //                                   viewportSize: projSize)
    //
    //        let u = proj.x / projSize.width
    //        let v = 1.0 - (proj.y / projSize.height)
    //
    //        if u < 0 || u > 1 || v < 0 || v > 1 {
    //            return SIMD3<UInt8>(128, 128, 128)
    //        }
    //
    //        let x = Int(u * CGFloat(frame.image.width))
    //        let y = Int(v * CGFloat(frame.image.height))
    //
    //        guard x >= 0, y >= 0, x < frame.image.width, y < frame.image.height,
    //              let data = frame.image.dataProvider?.data,
    //              let ptr = CFDataGetBytePtr(data) else {
    //            return SIMD3<UInt8>(128, 128, 128)
    //        }
    //
    //        let rowBytes = frame.image.bytesPerRow
    //        let offset = y * rowBytes + x * 4 // RGBA
    //        let r = ptr[offset]
    //        let g = ptr[offset + 1]
    //        let b = ptr[offset + 2]
    //
    //        return SIMD3<UInt8>(r, g, b)
    //    }
    
    private func sampleColor(worldPoint: SIMD3<Float>, frame: CapturedFrame) -> SIMD3<UInt8> {
        let camera = frame.camera
        let pointInCamera = camera.transform.inverse * SIMD4<Float>(worldPoint, 1)
        
        // Check if point is behind camera
        if pointInCamera.z <= 0 {
            return SIMD3<UInt8>(128, 128, 128)
        }
        
        // Project using intrinsics
        let xNorm = pointInCamera.x / pointInCamera.z
        let yNorm = pointInCamera.y / pointInCamera.z
        let intrinsics = camera.intrinsics
        let u = intrinsics[0][0] * xNorm + intrinsics[0][2]
        let v = intrinsics[1][1] * yNorm + intrinsics[1][2]
        
        // Convert image dimensions to Float
        let imageWidth = Float(frame.image.width)
        let imageHeight = Float(frame.image.height)
        
        // Check bounds
        if u < 0 || u >= imageWidth || v < 0 || v >= imageHeight {
            return SIMD3<UInt8>(128, 128, 128)
        }
        
        let x = Int(u)
        let y = Int(v)
        
        guard let data = frame.image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return SIMD3<UInt8>(128, 128, 128)
        }
        
        let rowBytes = frame.image.bytesPerRow
        let offset = y * rowBytes + x * 4 // RGBA
        let r = ptr[offset]
        let g = ptr[offset + 1]
        let b = ptr[offset + 2]
        
        return SIMD3<UInt8>(r, g, b)
    }
    
    func exportMultiTexturedMesh() {
        //        print("Starting export with \(meshAnchors.count) mesh anchors, \(planeAnchors.count) plane anchors, and \(capturedFrames.count) frames")
        //        guard !meshAnchors.isEmpty || !planeAnchors.isEmpty else {
        //            print("❌ No anchors collected. Try scanning longer.")
        //            return
        //        }
        //
        //        guard !capturedFrames.isEmpty else {
        //            print("❌ No frames collected. Try scanning longer.")
        //            return
        //        }
        //
        //        var vertices = [(SIMD3<Float>, SIMD3<UInt8>)]()
        //        var faces = [(Int, Int, Int)]()
        //        var faceNormals = [SIMD3<Float>]()
        //
        //        for anchorIndex in 0..<meshAnchors.count {
        //            let anchor = meshAnchors[anchorIndex]
        //            let geo = anchor.geometry
        //            let vb = geo.vertices.buffer.contents()
        //            let off = geo.vertices.offset
        //            let str = geo.vertices.stride
        //            let base = vertices.count
        //
        //            print("Processing mesh anchor \(anchorIndex+1)/\(meshAnchors.count): \(geo.vertices.count) vertices")
        //
        //            var worldVertices = [SIMD3<Float>]()
        //            for i in 0..<geo.vertices.count {
        //                let ptr = vb.advanced(by: off + i * str)
        //                var vtxLocal = SIMD3<Float>()
        //                memcpy(&vtxLocal, ptr, MemoryLayout<SIMD3<Float>>.size)
        //                let world4 = anchor.transform * SIMD4<Float>(vtxLocal, 1)
        //                let worldPos = SIMD3<Float>(world4.x, world4.y, world4.z)
        //                worldVertices.append(worldPos)
        //            }
        //
        //            let fb = geo.faces.buffer.contents()
        //            let bpi = geo.faces.bytesPerIndex
        //            for i in 0..<geo.faces.count {
        //                var idxs = [Int](repeating: 0, count: 3)
        //                for j in 0..<3 {
        //                    let ptr = fb.advanced(by: i * 3 * bpi + j * bpi)
        //                    let rawIndex: UInt32
        //                    switch bpi {
        //                    case 1:
        //                        rawIndex = UInt32(ptr.load(as: UInt8.self))
        //                    case 2:
        //                        rawIndex = UInt32(ptr.load(as: UInt16.self))
        //                    case 4:
        //                        rawIndex = ptr.load(as: UInt32.self)
        //                    default:
        //                        rawIndex = 0
        //                    }
        //                    idxs[j] = Int(rawIndex)
        //                }
        //
        //                if idxs.allSatisfy({ $0 < worldVertices.count }) {
        //                    let v0 = worldVertices[idxs[0]]
        //                    let v1 = worldVertices[idxs[1]]
        //                    let v2 = worldVertices[idxs[2]]
        //                    let edge1 = v1 - v0
        //                    let edge2 = v2 - v0
        //                    var normal = normalize(cross(edge1, edge2))
        //
        //                    let faceCenter = (v0 + v1 + v2) / 3.0
        //                    let toCenter = normalize(SIMD3<Float>(0, 0, 0) - faceCenter)
        //                    if dot(normal, toCenter) > 0 {
        //                        normal = -normal
        //                    }
        //
        //                    faceNormals.append(normal)
        //                    faces.append((idxs[0] + base, idxs[1] + base, idxs[2] + base))
        //                }
        //            }
        //
        //            for i in 0..<geo.vertices.count {
        //                let worldPos = worldVertices[i]
        //
        //                let vertexFaces = faces.enumerated().filter { $0.element.0 == i || $0.element.1 == i || $0.element.2 == i }.map { $0.offset }
        //                let avgNormal = vertexFaces.reduce(SIMD3<Float>(0, 0, 0)) { (sum, faceIdx) in
        //                    sum + faceNormals[faceIdx]
        //                } / Float(max(1, vertexFaces.count))
        //
        //                let bestFrame = bestFrameForPoint(worldPos, normal: avgNormal)
        //                let color: SIMD3<UInt8> = bestFrame != nil ? sampleColor(worldPoint: worldPos, frame: bestFrame!) : SIMD3<UInt8>(128, 128, 128)
        //
        //                vertices.append((worldPos, color))
        //            }
        //        }
        //
        //        guard vertices.count > 0, faces.count > 0 else {
        //            print("❌ Invalid mesh: \(vertices.count) vertices, \(faces.count) faces")
        //            return
        //        }
        //
        //        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        //        let timestamp = Int(Date().timeIntervalSince1970)
        //        let fileURL = docs.appendingPathComponent("ColoredMesh_\(timestamp).ply")
        //        var ply = """
        //ply
        //format ascii 1.0
        //element vertex \(vertices.count)
        //property float x
        //property float y
        //property float z
        //property uchar red
        //property uchar green
        //property uchar blue
        //element face \(faces.count)
        //property list uchar int vertex_indices
        //end_header
        //"""
        //        for (pos, col) in vertices {
        //            ply += "\n\(pos.x) \(pos.y) \(pos.z) \(col.x) \(col.y) \(col.z)"
        //        }
        //
        //        for (a, b, c) in faces {
        //            ply += "\n3 \(a) \(b) \(c)"
        //        }
        //
        //        do {
        //            try ply.write(to: fileURL, atomically: true, encoding: .utf8)
        //            print("✅ Saved to \(fileURL.lastPathComponent) with \(vertices.count) vertices and \(faces.count) faces")
        //        } catch {
        //            print("❌ Write error: \(error)")
        //        }
        //    }
        //
        //    func session(_ session: ARSession, didFailWithError error: Error) {
        //        print("❌ ARSession failed: \(error.localizedDescription)")
        //    }
        //
        //    func sessionWasInterrupted(_ session: ARSession) {
        //        print("⚠️ Interrupted")
        //    }
        //
        //    func sessionInterruptionEnded(_ session: ARSession) {
        //        print("✅ Resumed")
        //    }
        //        func exportColoredPointCloud() {

            print("Starting export with \(meshAnchors.count) mesh anchors and \(capturedFrames.count) frames")
            
            guard !meshAnchors.isEmpty else {
                print("❌ No mesh anchors collected. Try scanning longer.")
                return
            }
            
            guard !capturedFrames.isEmpty else {
                print("❌ No frames collected. Try scanning longer.")
                return
            }

            var vertices = [(SIMD3<Float>, SIMD3<UInt8>)]()
            var defaultColorCount = 0

            for anchor in meshAnchors {
                let geo = anchor.geometry
                let transform = anchor.transform

                // Extract vertices
                let vb = geo.vertices.buffer.contents()
                var localVertices = [SIMD3<Float>]()
                for i in 0..<geo.vertices.count {
                    let ptr = vb.advanced(by: geo.vertices.offset + i * geo.vertices.stride)
                    var vtx = SIMD3<Float>()
                    memcpy(&vtx, ptr, MemoryLayout<SIMD3<Float>>.size)
                    localVertices.append(vtx)
                }

                // Extract faces (assuming triangles)
                let fb = geo.faces.buffer.contents()
                var faces = [[Int]]()
                for i in 0..<geo.faces.count {
                    var face = [Int]()
                    for j in 0..<geo.faces.indexCountPerPrimitive {
                        let index = fb.advanced(by: i * geo.faces.indexCountPerPrimitive * 4 + j * 4).load(as: UInt32.self)
                        face.append(Int(index))
                    }
                    faces.append(face)
                }

                // Compute face normals
                var faceNormals = [SIMD3<Float>]()
                for face in faces {
                    let v0 = localVertices[face[0]]
                    let v1 = localVertices[face[1]]
                    let v2 = localVertices[face[2]]
                    let edge1 = v1 - v0
                    let edge2 = v2 - v0
                    let normal = normalize(cross(edge1, edge2))
                    faceNormals.append(normal)
                }

                // Compute vertex normals
                var vertexNormals = [SIMD3<Float>](repeating: .zero, count: localVertices.count)
                for faceIndex in 0..<faces.count {
                    let face = faces[faceIndex]
                    let normal = faceNormals[faceIndex]
                    for vertexIndex in face {
                        vertexNormals[vertexIndex] += normal
                    }
                }
                for i in 0..<vertexNormals.count {
                    vertexNormals[i] = normalize(vertexNormals[i])
                }

                // Process vertices
                for i in 0..<localVertices.count {
                    let vtxLocal = localVertices[i]
                    let normalLocal = vertexNormals[i]

                    // Transform to world space
                    let world4 = transform * SIMD4<Float>(vtxLocal, 1)
                    let worldPos = SIMD3<Float>(world4.x, world4.y, world4.z)
                    let rotation = float3x3(
                        SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                        SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                        SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                    )
                    let worldNormal = normalize(rotation * normalLocal)

                    // Get best frame and color
                    let bestFrame = bestFrameForPoint(worldPos, normal: worldNormal)
                    let color: SIMD3<UInt8>
                    if let frame = bestFrame {
                        color = sampleColor(worldPoint: worldPos, frame: frame)
                    } else {
                        color = SIMD3<UInt8>(128, 128, 128)
                        defaultColorCount += 1
                    }
                    
                    vertices.append((worldPos, color))
                    
                    if i < 5 {
                        print("Point \(i): position \(worldPos), color \(color)")
                    }
                }
            }

            print("Vertices with default color: \(defaultColorCount) out of \(vertices.count)")
            
            guard vertices.count > 0 else {
                print("❌ No vertices collected.")
                return
            }
            
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = Int(Date().timeIntervalSince1970)
            let fileURL = docs.appendingPathComponent("ColoredPointCloud_\(timestamp).ply")
            var ply = """
            ply
            format ascii 1.0
            element vertex \(vertices.count)
            property float x
            property float y
            property float z
            property uchar red
            property uchar green
            property uchar blue
            end_header
            """
            for (pos, col) in vertices {
                ply += "\n\(pos.x) \(pos.y) \(pos.z) \(col.x) \(col.y) \(col.z)"
            }
            
            do {
                try ply.write(to: fileURL, atomically: true, encoding: .utf8)
                print("✅ Saved point cloud to \(fileURL.lastPathComponent) with \(vertices.count) points")
            } catch {
                print("❌ Write error: \(error)")
            }
        }
}
