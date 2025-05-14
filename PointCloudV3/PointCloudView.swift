
// PointCloudView.swift
// PointCloudV3
// Created by ihub-devs on 13/05/25.

import SwiftUI
import SceneKit

/// SwiftUI view that presents a SceneKit-based point-cloud viewer in a sheet.
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


/// UIViewRepresentable that loads an ASCII-PLY file and renders it as true SceneKit points,
/// plus adds camera, lighting, and a floor for better visibility.
struct SceneKitColoredMeshScene: UIViewRepresentable {
    let plyURL: URL

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.allowsCameraControl = true
        scnView.backgroundColor = .black

        if let node = makeMeshNode() {
            scnView.scene?.rootNode.addChildNode(node)

            // Add camera
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 0, 1)
            scnView.scene?.rootNode.addChildNode(cameraNode)
            scnView.pointOfView = cameraNode

            // Lighting
            let light = SCNNode()
            light.light = SCNLight()
            light.light?.type = .ambient
            light.light?.color = UIColor.white
            scnView.scene?.rootNode.addChildNode(light)
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func makeMeshNode() -> SCNNode? {
        guard
            let text = try? String(contentsOf: plyURL, encoding: .utf8),
            let headerEnd = text.range(of: "end_header\n")
        else { return nil }

        let lines = text[headerEnd.upperBound...].split(separator: "\n")
        let header = text[..<headerEnd.lowerBound]
        guard
            let vertexLine = header.split(separator: "\n").first(where: { $0.contains("element vertex") }),
            let faceLine = header.split(separator: "\n").first(where: { $0.contains("element face") }),
            let vertexCount = Int(vertexLine.split(separator: " ").last ?? ""),
            let faceCount = Int(faceLine.split(separator: " ").last ?? "")
        else { return nil }

        let vertexLines = lines.prefix(vertexCount)
        let faceLines = lines.dropFirst(vertexCount).prefix(faceCount)

        var verts = [SCNVector3]()
        var colors = [SCNVector3]()

        for line in vertexLines {
            let comps = line.split(separator: " ")
            guard comps.count >= 6,
                  let x = Float(comps[0]),
                  let y = Float(comps[1]),
                  let z = Float(comps[2]),
                  let r = Float(comps[3]),
                  let g = Float(comps[4]),
                  let b = Float(comps[5])
            else { continue }
            verts.append(SCNVector3(x, y, z))
            colors.append(SCNVector3(r/255, g/255, b/255))
        }

        var indices: [UInt32] = []
        for line in faceLines {
            let comps = line.split(separator: " ")
            guard comps.count == 4, comps[0] == "3",
                  let i0 = UInt32(comps[1]),
                  let i1 = UInt32(comps[2]),
                  let i2 = UInt32(comps[3])
            else { continue }
            indices.append(contentsOf: [i0, i1, i2])
        }

        let vertexSource = SCNGeometrySource(vertices: verts)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector3>.stride)
        let colorSource = SCNGeometrySource(data: colorData,
                                            semantic: .color,
                                            vectorCount: colors.count,
                                            usesFloatComponents: true,
                                            componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.stride,
                                            dataOffset: 0,
                                            dataStride: MemoryLayout<SCNVector3>.stride)

        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let element = SCNGeometryElement(data: indexData,
                                         primitiveType: .triangles,
                                         primitiveCount: indices.count / 3,
                                         bytesPerIndex: MemoryLayout<UInt32>.stride)

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        geometry.firstMaterial?.isDoubleSided = true
        geometry.firstMaterial?.lightingModel = .blinn

        return SCNNode(geometry: geometry)
    }
}


