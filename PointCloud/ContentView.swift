import SwiftUI
import RealityKit
import ARKit
import SceneKit

class ARViewModel: ObservableObject {
    @Published var arView: ARView?
}

struct ContentView: View {
    @StateObject var arViewModel = ARViewModel()
    @State private var isSaving = false

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
            }
        }
    }

    func saveMesh() {
        print("Save Mesh button pressed.")
        isSaving = true

        if let arView = arViewModel.arView {
            print("ARView found.")
            if let coordinator = arView.session.delegate as? ARSessionDelegateCoordinator {
                print("Coordinator found. Starting mesh export...")
                DispatchQueue.global(qos: .userInitiated).async {
                    coordinator.exportPointCloud()
                    DispatchQueue.main.async {
                        self.isSaving = false
                    }
                }
            } else {
                print("Coordinator not found.")
                isSaving = false
            }
        } else {
            print("ARView not found.")
            isSaving = false
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @EnvironmentObject var arViewModel: ARViewModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else {
            print("Scene reconstruction is not supported on this device.")
        }
        arView.session.run(configuration)
        arView.debugOptions = [.showSceneUnderstanding, .showFeaturePoints]

        arView.session.delegate = context.coordinator
        arViewModel.arView = arView
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> ARSessionDelegateCoordinator {
        return ARSessionDelegateCoordinator()
    }
}

class ARSessionDelegateCoordinator: NSObject, ARSessionDelegate {
    var meshAnchors: [ARMeshAnchor] = []

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        print("Added anchors: \(anchors.count)")
        updateMeshAnchors(with: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        print("Updated anchors: \(anchors.count)")
        updateMeshAnchors(with: anchors)
    }

    private func updateMeshAnchors(with anchors: [ARAnchor]) {
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                if !meshAnchors.contains(where: { $0.identifier == meshAnchor.identifier }) {
                    print("Mesh anchor added with identifier: \(meshAnchor.identifier)")
                    meshAnchors.append(meshAnchor)
                }
            }
        }
    }

    func exportPointCloud() {
        print("Exporting point cloud...")
        guard !meshAnchors.isEmpty else {
            print("No mesh data available to export.")
            return
        }

        var pointCloudData = "ply\nformat ascii 1.0\n"
        var points = [String]()
        var totalPointCount = 0

        for meshAnchor in meshAnchors {
            let meshGeometry = meshAnchor.geometry
            let vertexCount = meshGeometry.vertices.count

            let vertexBuffer = meshGeometry.vertices.buffer.contents()
            let vertexStride = meshGeometry.vertices.stride
            let vertexOffset = meshGeometry.vertices.offset

            for i in 0..<vertexCount {
                let offset = vertexOffset + i * vertexStride
                var vertex = SIMD3<Float>(0, 0, 0) // Temporary aligned storage
                memcpy(&vertex, vertexBuffer.advanced(by: offset), MemoryLayout<SIMD3<Float>>.size)
                let position = simd_make_float4(vertex, 1.0)
                let worldPosition = simd_mul(meshAnchor.transform, position)
                points.append("\(worldPosition.x) \(worldPosition.y) \(worldPosition.z)")
            }
            totalPointCount += vertexCount
        }

        pointCloudData += "element vertex \(totalPointCount)\n"
        pointCloudData += "property float x\nproperty float y\nproperty float z\n"
        pointCloudData += "end_header\n"
        pointCloudData += points.joined(separator: "\n")

        let fileManager = FileManager.default
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = documentsURL.appendingPathComponent("PointCloud.ply")

            do {
                try pointCloudData.write(to: fileURL, atomically: true, encoding: .utf8)
                print("Point cloud successfully saved at: \(fileURL)")
            } catch {
                print("Failed to save point cloud: \(error.localizedDescription)")
            }
        }
    }
}
