// PointCloudView.swift
// PointCloudV3
// Updated for rendering high-accuracy colored mesh

import SwiftUI
import SceneKit
import UIKit
import ModelIO // For mesh generation

struct PointCloudView: View {
    let plyURL: URL
    @Environment(\.presentationMode) private var presentationMode
    @State private var isProcessing = false
    @State private var processResult: (success: Bool, message: String)? = nil
    @State private var showResult = false

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
                
                // Add button to convert to textured mesh
                Button(action: {
                    convertToTexturedMesh()
                }) {
                    Text(isProcessing ? "Processing..." : "Convert to Textured Mesh")
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(isProcessing ? Color.gray : Color.green)
                        .cornerRadius(10)
                        .padding(.horizontal)
                        .shadow(radius: 5)
                }
                .disabled(isProcessing)
                .padding(.bottom, 30)
            }
        }
        .alert(isPresented: $showResult) {
            Alert(
                title: Text(processResult?.success == true ? "Success" : "Error"),
                message: Text(processResult?.message ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    
    private func convertToTexturedMesh() {
        isProcessing = true
        
        // Get the directory containing the point cloud
        let pointCloudDirectory = plyURL.deletingLastPathComponent()
        let outputFilename = plyURL.deletingPathExtension().lastPathComponent + "_mesh"
        
        // Process in background
        DispatchQueue.global(qos: .userInitiated).async {
            // outputFilename is defined in the outer scope: let outputFilename = plyURL.deletingPathExtension().lastPathComponent + "_mesh"
            // pointCloudDirectory is defined in the outer scope: let pointCloudDirectory = plyURL.deletingLastPathComponent()

            print("DEBUG: Calling MeshGenerator.generateTexturedMesh with inputDir: \(pointCloudDirectory), plyFile: \(String(describing: plyURL)), outputFilename: \(outputFilename)")
            let result = MeshGenerator.generateTexturedMesh(
                inputDirectory: pointCloudDirectory,
                inputPLYFile: plyURL,
                outputFilename: outputFilename // This is the base name, MeshGenerator handles extension
            )
            
            // Update UI on main thread
            DispatchQueue.main.async {
                self.isProcessing = false
                
                if result.success {
                    self.processResult = (success: true, message: "Textured mesh operation completed. Output at:\n\(result.outputURL?.path ?? "Path not available.")")
                    if let outputPath = result.outputURL?.path {
                        print("DEBUG: Mesh generation successful. Output: \(outputPath)")
                    } else {
                        print("DEBUG: Mesh generation successful, but output URL is nil.")
                    }
                } else {
                    self.processResult = (success: false, message: "Failed to create textured mesh. Please check debug logs for details.")
                    print("DEBUG: Mesh generation failed.")
                }
                self.showResult = true
            }
        }
    }
    
    /// Load a PLY file and extract point cloud data with colors
    /// - Parameter url: The URL of the PLY file to load
    /// - Returns: Array of points with position, color, and confidence values
    private func loadPLYPointCloud(from url: URL) -> [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)]? {
        print("Loading PLY file: \(url.lastPathComponent)")
        
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let headerEnd = text.range(of: "end_header\n") else {
                print("❌ Invalid PLY file: Header end not found")
                return nil
            }
            
            // Parse header to find vertex count
            let header = text[..<headerEnd.lowerBound]
            guard let vertexLine = header.split(separator: "\n").first(where: { $0.contains("element vertex") }),
                  let vertexCount = Int(vertexLine.split(separator: " ").last ?? "") else {
                print("❌ Invalid PLY header: Vertex count not found")
                return nil
            }
            
            print("PLY file contains \(vertexCount) vertices")
            
            // Find if file has color information
            let hasColors = header.contains("property uchar red") || header.contains("property uchar r")
            
            // Parse vertex data
            let bodyStart = text.index(after: headerEnd.upperBound)
            let vertexDataString = text[bodyStart...]
            let lines = vertexDataString.split(separator: "\n").prefix(vertexCount)
            
            var result = [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)]()
            
            for line in lines {
                let components = line.split(separator: " ")
                
                // Each line should have at least x, y, z coordinates
                guard components.count >= 3,
                      let x = Float(components[0]),
                      let y = Float(components[1]),
                      let z = Float(components[2]) else {
                    continue
                }
                
                let position = simd_float3(x, y, z)
                var color = SIMD3<UInt8>(128, 128, 128) // Default gray if no color
                let confidence: Float = 1.0 // Default confidence
                
                // If file has color information and we have enough components
                if hasColors && components.count >= 6 {
                    // Try to parse color values (usually r, g, b as 3 separate components)
                    if let r = UInt8(components[3]),
                       let g = UInt8(components[4]),
                       let b = UInt8(components[5]) {
                        color = SIMD3<UInt8>(r, g, b)
                    }
                }
                
                result.append((position: position, color: color, confidence: confidence))
            }
            
            print("Successfully loaded \(result.count) colored points from PLY file")
            return result
            
        } catch {
            print("❌ Error loading PLY file: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Generate a mesh from a point cloud and save to file
    /// - Parameters:
    ///   - pointCloud: Array of points with position, color, and confidence
    ///   - outputPath: Path to save the generated mesh
    /// - Returns: Result tuple with success flag and output path
    private func generateMesh(
        from pointCloud: [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)],
        outputPath: URL
    ) -> (success: Bool, outputPath: URL?) {
        print("Generating mesh from \(pointCloud.count) points")
        
        // Memory optimization: Use batched processing
        let batchSize = 1000 // Process 1000 points at a time to avoid memory issues
        
        // Create SCNGeometry sources with memory optimization
        var vertices = [SCNVector3]()
        var colors = [SCNVector3]()
        
        // Process in batches to prevent memory issues
        let totalPoints = pointCloud.count
        let batches = (totalPoints + batchSize - 1) / batchSize
        
        print("Processing \(totalPoints) points in \(batches) batches")
        
        for batchIndex in 0..<batches {
            // Using autoreleasepool to free memory after each batch
            autoreleasepool {
                let start = batchIndex * batchSize
                let end = min(start + batchSize, totalPoints)
                let currentBatch = pointCloud[start..<end]
                
                // Process each point in the batch
                for point in currentBatch {
                    // Add vertex
                    vertices.append(SCNVector3(point.position.x, point.position.y, point.position.z))
                    
                    // Convert color from UInt8 to float (0-1 range)
                    let normalizedColor = SCNVector3(
                        CGFloat(point.color.x) / 255.0,
                        CGFloat(point.color.y) / 255.0,
                        CGFloat(point.color.z) / 255.0
                    )
                    colors.append(normalizedColor)
                }
                
                // Report progress
                if batchIndex % 5 == 0 || batchIndex == batches - 1 {
                    let progress = Float(end) / Float(totalPoints) * 100.0
                    print("Processed batch \(batchIndex + 1)/\(batches) (\(Int(progress))%)")
                }
            }
        }
        
        // Create geometry sources
        let vertexSource = SCNGeometrySource(vertices: vertices)
        
        // Create color source
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector3>.size)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<CGFloat>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.size
        )
        
        // Try to create a mesh using ModelIO
        do {
            // Create MDLAsset for mesh generation
            let mdlVertexDescriptor = MDLVertexDescriptor()
            mdlVertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                                 format: .float3,
                                                                 offset: 0,
                                                                 bufferIndex: 0)
            mdlVertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeColor,
                                                                 format: .float3,
                                                                 offset: 0,
                                                                 bufferIndex: 1)
            mdlVertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
            mdlVertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
            
            // Create MDL data
            var mdlVertices = [SIMD3<Float>]()
            var mdlColors = [SIMD3<Float>]()
            
            for point in pointCloud {
                mdlVertices.append(point.position)
                mdlColors.append(SIMD3<Float>(
                    Float(point.color.x) / 255.0,
                    Float(point.color.y) / 255.0,
                    Float(point.color.z) / 255.0
                ))
            }
            
            // Create MDL mesh
            let allocator = MDLMeshBufferDataAllocator()
            
            let vertexBuffer = allocator.newBuffer(with: Data(bytes: mdlVertices, count: mdlVertices.count * MemoryLayout<SIMD3<Float>>.stride), type: .vertex)
            let colorBuffer = allocator.newBuffer(with: Data(bytes: mdlColors, count: mdlColors.count * MemoryLayout<SIMD3<Float>>.stride), type: .vertex)
            
            // Create mesh asset
            let asset = MDLAsset()
            
            // Create submesh
            let submesh = MDLSubmesh(
                indexBuffer: allocator.newBuffer(with: Data(), type: .index),
                indexCount: 0,
                indexType: .uInt32,
                geometryType: .triangles,
                material: nil
            )
            
            // Create MDLMesh
            let mesh = MDLMesh(
                vertexBuffers: [vertexBuffer, colorBuffer],
                vertexCount: mdlVertices.count,
                descriptor: mdlVertexDescriptor,
                submeshes: [submesh]
            )
            
            // Create MDLAsset
            asset.add(mesh)
            
            // Create SCNScene from MDLAsset
            let scene = SCNScene(mdlAsset: asset)
            
            // Ensure output directory exists
            let outputDirectory = outputPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            
            // Export as OBJ file
            if scene.write(to: outputPath, options: nil, delegate: nil, progressHandler: nil) {
                print("✅ Successfully exported mesh to: \(outputPath.path)")
                return (true, outputPath)
            } else {
                print("❌ Failed to write mesh to file")
                return (false, nil)
            }
        } catch {
            print("❌ Error generating mesh: \(error.localizedDescription)")
            
            // Fallback to basic point cloud if mesh generation fails
            print("⚠️ Falling back to basic point cloud export")
            
            do {
                // Create element with points
                let indices = (0..<vertices.count).map { UInt32($0) }
                let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
                let element = SCNGeometryElement(
                    data: indexData,
                    primitiveType: .point,
                    primitiveCount: vertices.count,
                    bytesPerIndex: MemoryLayout<UInt32>.size
                )
                
                // Create geometry
                let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
                
                // Create node
                let node = SCNNode(geometry: geometry)
                
                // Create scene
                let scene = SCNScene()
                scene.rootNode.addChildNode(node)
                
                // Export as DAE file (Collada - better for point clouds)
                let daeOutput = outputPath.deletingPathExtension().appendingPathExtension("dae")
                
                if scene.write(to: daeOutput, options: nil, delegate: nil, progressHandler: nil) {
                    print("✅ Successfully exported point cloud to: \(daeOutput.path)")
                    return (true, daeOutput)
                } else {
                    print("❌ Failed to write point cloud to file")
                    return (false, nil)
                }
            } catch {
                print("❌ Error in fallback export: \(error.localizedDescription)")
                return (false, nil)
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
