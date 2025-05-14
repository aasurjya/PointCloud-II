import SwiftUI
import RealityKit
import ARKit
import Foundation

class ARViewModel: ObservableObject {
    @Published var arView: ARView?
}

struct ContentView: View {
    @StateObject private var arViewModel = ARViewModel()
    @State private var isSaving = false
    @State private var showBrowser = false

    var body: some View {
        ZStack {
            ARViewContainer()
                .edgesIgnoringSafeArea(.all)
                .environmentObject(arViewModel)

            VStack {
                Spacer()

                Button(action: saveMesh) {
                    Text(isSaving ? "Saving..." : "Save Mesh")
                        .padding()
                        .background(isSaving ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
                .disabled(isSaving)

                Button(action: { showBrowser.toggle() }) {
                    Text("Browse Meshes")
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.bottom)
            }
            .sheet(isPresented: $showBrowser) {
                FileBrowserView()
                    .environmentObject(arViewModel)
            }
        }
    }

    private func saveMesh() {
        guard let arView = arViewModel.arView,
              let coord = arView.session.delegate as? ARSessionDelegateCoordinator else {
            print("❌ ARView or coordinator not found.")
            return
        }

        guard let frame = arView.session.currentFrame else {
            print("❌ No current AR frame available.")
            return
        }

        coord.meshAnchors.removeAll()
        coord.planeAnchors.removeAll()

        isSaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            coord.exportColorMeshWithPlanes(with: frame)
            self.isSaving = false
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @EnvironmentObject var arViewModel: ARViewModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        var config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]

        arView.session.run(config)
        arView.debugOptions = [.showSceneUnderstanding, .showFeaturePoints]
        arView.session.delegate = context.coordinator
        arViewModel.arView = arView
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> ARSessionDelegateCoordinator {
        ARSessionDelegateCoordinator()
    }
}

struct FileBrowserViews: View {
    @EnvironmentObject var arViewModel: ARViewModel
    @State private var files: [URL] = []

    var body: some View {
        NavigationView {
            List(files, id: \.self) { file in
                Text(file.lastPathComponent)
            }
            .navigationTitle("Saved Meshes")
            .onAppear {
                loadFiles()
            }
        }
    }

    private func loadFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
            self.files = contents.filter { $0.pathExtension == "ply" }
        } catch {
            print("❌ Failed to load files: \(error)")
        }
    }
}

class ARSessionDelegateCoordinator: NSObject, ARSessionDelegate {
    var meshAnchors = [ARMeshAnchor]()
    var planeAnchors = [ARPlaneAnchor]()

    func exportColorMeshWithPlanes(with frame: ARFrame) {
        // Directly access capturedImage since it is non-optional
        let pixelBuffer = frame.capturedImage

        // Lock the pixel buffer to access its memory
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        if status != kCVReturnSuccess {
            print("❌ Failed to lock pixel buffer: Error code \(status).")
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Check for nil pointers directly for pixel buffer planes
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        if yBase == nil || uvBase == nil {
            print("❌ Unable to access pixel buffer planes: One or both planes are nil.")
            return
        }

        let wImg = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let hImg = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let rowUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let K = frame.camera.intrinsics
        let camInv = frame.camera.transform.inverse

        var vertices: [(SIMD3<Float>, SIMD3<UInt8>)] = []
        var faces: [(Int, Int, Int)] = []

        // Function to sample color from YUV image data
        func sampleColor(px: Int, py: Int) -> SIMD3<UInt8> {
            guard px >= 0 && px < wImg && py >= 0 && py < hImg else { return SIMD3(255, 255, 255) }
            let Y = yBase!.load(fromByteOffset: py * rowY + px, as: UInt8.self)
            let uvX = px / 2, uvY = py / 2
            let uvIdx = uvY * rowUV + uvX * 2
            let Cb = uvBase!.load(fromByteOffset: uvIdx, as: UInt8.self)
            let Cr = uvBase!.load(fromByteOffset: uvIdx + 1, as: UInt8.self)

            let Yf = Float(Y) - 16
            let Cbf = Float(Cb) - 128
            let Crf = Float(Cr) - 128

            var r = 1.164 * Yf + 1.596 * Crf
            var g = 1.164 * Yf - 0.392 * Cbf - 0.813 * Crf
            var b = 1.164 * Yf + 2.017 * Cbf
            r = max(0, min(255, r))
            g = max(0, min(255, g))
            b = max(0, min(255, b))

            return SIMD3(UInt8(r), UInt8(g), UInt8(b))
        }

        // Process mesh anchors
        for anchor in meshAnchors {
            let geo = anchor.geometry
            let vb = geo.vertices.buffer.contents()
            let base = vertices.count

            for i in 0..<geo.vertices.count {
                let ptr = vb.advanced(by: geo.vertices.offset + i * geo.vertices.stride)
                var vtx = SIMD3<Float>()
                memcpy(&vtx, ptr, MemoryLayout<SIMD3<Float>>.size)
                let wp = anchor.transform * SIMD4<Float>(vtx, 1)
                let world = SIMD3<Float>(wp.x, wp.y, wp.z)

                // Break up complex expressions to help the compiler
                let cam = camInv * SIMD4<Float>(world, 1)
                let xDivZ = cam.x / cam.z
                let yDivZ = cam.y / cam.z
                let u = K[0, 0] * xDivZ + K[2, 0]
                let v = K[1, 1] * yDivZ + K[2, 1]
                let px = Int(round(u))
                let py = Int(round(v))

                vertices.append((world, sampleColor(px: px, py: py)))
            }

            let fb = geo.faces.buffer.contents()
            for i in 0..<geo.faces.count {
                let ptr = fb.advanced(by: i * geo.faces.bytesPerIndex * 3)
                let i0 = ptr.load(as: UInt32.self)
                let i1 = ptr.advanced(by: geo.faces.bytesPerIndex).load(as: UInt32.self)
                let i2 = ptr.advanced(by: geo.faces.bytesPerIndex * 2).load(as: UInt32.self)
                faces.append((base + Int(i0), base + Int(i1), base + Int(i2)))
            }
        }

        // Process plane anchors
        for anchor in planeAnchors {
            let center = anchor.center
            let extent = anchor.extent
            let t = anchor.transform

            let corners = [
                SIMD3<Float>(center.x - extent.x/2, 0, center.z - extent.z/2),
                SIMD3<Float>(center.x + extent.x/2, 0, center.z - extent.z/2),
                SIMD3<Float>(center.x + extent.x/2, 0, center.z + extent.z/2),
                SIMD3<Float>(center.x - extent.x/2, 0, center.z + extent.z/2)
            ]

            let base = vertices.count
            for pt in corners {
                let wp = t * SIMD4<Float>(pt, 1)
                vertices.append((SIMD3(wp.x, wp.y, wp.z), SIMD3<UInt8>(128, 255, 128))) // Light green
            }

            faces.append((base, base+1, base+2))
            faces.append((base, base+2, base+3))
        }

        writeColoredPLY(vertices: vertices, faces: faces)
    }

    func writeColoredPLY(vertices: [(SIMD3<Float>, SIMD3<UInt8>)], faces: [(Int, Int, Int)]) {
        let N = vertices.count
        let F = faces.count
        guard N > 0, F > 0 else {
            print("❌ No valid data to export. Vertices: \(N), Faces: \(F)")
            return
        }

        let fileName = "ColoredMesh_\(Int(Date().timeIntervalSince1970)).ply"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(fileName)

        var ply = """
        ply
        format ascii 1.0
        element vertex \(N)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(F)
        property list uchar int vertex_indices
        end_header
        """

        for (pos, rgb) in vertices {
            ply += "\n\(pos.x) \(pos.y) \(pos.z) \(rgb.x) \(rgb.y) \(rgb.z)"
        }

        for (a, b, c) in faces {
            ply += "\n3 \(a) \(b) \(c)"
        }

        do {
            try ply.write(to: url, atomically: true, encoding: .utf8)
            print("✅ Exported colored mesh to: \(url.lastPathComponent)")
        } catch {
            print("❌ Failed to write colored mesh: \(error)")
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                meshAnchors.append(mesh)
            } else if let plane = anchor as? ARPlaneAnchor {
                planeAnchors.append(plane)
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                if let index = meshAnchors.firstIndex(where: { $0.identifier == mesh.identifier }) {
                    meshAnchors[index] = mesh
                } else {
                    meshAnchors.append(mesh)
                }
            } else if let plane = anchor as? ARPlaneAnchor {
                if let index = planeAnchors.firstIndex(where: { $0.identifier == plane.identifier }) {
                    planeAnchors[index] = plane
                } else {
                    planeAnchors.append(plane)
                }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("❌ AR Session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        print("⚠️ AR Session was interrupted.")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        print("✅ AR Session interruption ended.")
    }
}
