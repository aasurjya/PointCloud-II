// PointCloudView.swift
// PointCloudV3
// Updated for rendering high-accuracy colored mesh

import SwiftUI
import SceneKit

struct PointCloudView: View {
    let plyURL: URL
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        ZStack {
            SceneKitColoredMeshScene(plyURL: plyURL)
                .edgesIgnoringSafeArea(.all)
            VStack {
                HStack {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .padding()
                    .background(Color.white.opacity(0.8))
                    .cornerRadius(8)
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

struct SceneKitColoredMeshScene: UIViewRepresentable {
    let plyURL: URL

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.allowsCameraControl = true
        scnView.backgroundColor = .black
        scnView.antialiasingMode = .multisampling4X

        if let node = makeMeshNode() {
            scnView.scene?.rootNode.addChildNode(node)

            // Add camera
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 60
            cameraNode.position = SCNVector3(0, 0, 2)
            scnView.scene?.rootNode.addChildNode(cameraNode)
            scnView.pointOfView = cameraNode

            // Add lighting
            let ambientLight = SCNNode()
            ambientLight.light = SCNLight()
            ambientLight.light?.type = .ambient
            ambientLight.light?.intensity = 500
            scnView.scene?.rootNode.addChildNode(ambientLight)

            let directionalLight = SCNNode()
            directionalLight.light = SCNLight()
            directionalLight.light?.type = .directional
            directionalLight.light?.intensity = 1000
            directionalLight.position = SCNVector3(10, 10, 10)
            directionalLight.look(at: SCNVector3(0, 0, 0))
            scnView.scene?.rootNode.addChildNode(directionalLight)
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func makeMeshNode() -> SCNNode? {
            guard let text = try? String(contentsOf: plyURL, encoding: .utf8),
                  let headerEnd = text.range(of: "end_header\n") else {
                print("❌ Failed to load PLY file: Header end not found.")
                return nil
            }

            let header = text[..<headerEnd.lowerBound]
            guard let vertexLine = header.split(separator: "\n").first(where: { $0.contains("element vertex") }),
                  let vertexCount = Int(vertexLine.split(separator: " ").last ?? "") else {
                print("❌ Invalid PLY header: Vertex element or count not found.")
                return nil
            }

            // Find the start of the vertex data in the body
            let bodyStart = text.index(after: headerEnd.upperBound)
            let vertexDataString = text[bodyStart...]

            var verts = [SCNVector3]()
            var colors = [SCNVector3]()

            let lines = vertexDataString.split(separator: "\n").prefix(vertexCount)

            for line in lines {
                let comps = line.split(separator: " ")
                guard comps.count >= 6,
                      let x = Float(comps[0]),
                      let y = Float(comps[1]),
                      let z = Float(comps[2]),
                      let r = Float(comps[3]),
                      let g = Float(comps[4]),
                      let b = Float(comps[5]) else {
                    print("⚠️ Skipping invalid vertex line: \(line)")
                    continue
                }
                verts.append(SCNVector3(x, y, z))
                colors.append(SCNVector3(r/255, g/255, b/255)) // Normalize color to 0-1
            }

            guard verts.count == vertexCount, verts.count == colors.count else {
                 print("❌ Mismatch between header vertex count and actual valid vertex lines read.")
                 return nil
            }
            
            guard !verts.isEmpty else {
                print("❌ No valid vertices found in PLY.")
                return nil
            }

            let vertexSource = SCNGeometrySource(vertices: verts)

            // Create color source
            let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector3>.stride)
            let colorSource = SCNGeometrySource(data: colorData,
                                                semantic: .color,
                                                vectorCount: colors.count,
                                                usesFloatComponents: true, // Colors are 0-1 floats now
                                                componentsPerVector: 3,
                                                bytesPerComponent: MemoryLayout<Float>.stride,
                                                dataOffset: 0,
                                                dataStride: MemoryLayout<SCNVector3>.stride)

            // Create geometry element for points
            var pointIndices = (0..<verts.count).map { UInt32($0) }
            let indexData = Data(bytes: pointIndices, count: pointIndices.count * MemoryLayout<UInt32>.stride)
            let element = SCNGeometryElement(data: indexData,
                                             primitiveType: .point, // Use .point primitive type
                                             primitiveCount: verts.count, // Primitive count is the number of points
                                             bytesPerIndex: MemoryLayout<UInt32>.stride)

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            geometry.firstMaterial?.lightingModel = .constant // Use constant lighting for point clouds to see vertex colors directly
            geometry.firstMaterial?.diffuse.contents = UIColor.white // This is often ignored when vertex colors are used, but good practice.
            geometry.firstMaterial?.readsFromDepthBuffer = true // Helps with rendering order

            // Optional: Increase point size if needed for visibility
//            geometry.firstMaterial?.pointSize = 2.0 // Adjust size as needed
//            geometry.firstMaterial?.minimumPointScreenSpaceRadius = 1.0
//            geometry.firstMaterial?.maximumPointScreenSpaceRadius = 10.0


            return SCNNode(geometry: geometry)
        }
}
