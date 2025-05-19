// MeshGenerator.swift
// PointCloudV3
// Created for converting point clouds to textured meshes

import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import MetalKit
import ARKit
import UIKit

/// A class for generating textured meshes from point cloud data
class MeshGenerator {
    
    /// Generates a textured mesh from a PLY file
    /// - Parameters:
    ///   - inputDirectory: Directory containing PLY file
    ///   - inputPLYFile: Optional specific PLY file to convert
    ///   - outputFilename: Filename for the output OBJ file
    /// - Returns: Success status and URL to the generated mesh file
    static func generateTexturedMesh(
        inputDirectory: URL,
        inputPLYFile: URL? = nil,
        outputFilename: String = "textured_mesh"
    ) -> (success: Bool, outputURL: URL?) {
        print("DEBUG: Starting generateTexturedMesh")
        print("Starting mesh generation from point cloud")
        
        // Use specified PLY file or find one in directory
        let plyFile: URL
        print("DEBUG: About to check for PLY file")
        
        if let specifiedPLY = inputPLYFile {
            guard specifiedPLY.pathExtension.lowercased() == "ply" else {
                print("❌ Specified file is not a PLY file")
                return (false, nil)
            }
            plyFile = specifiedPLY
            print("DEBUG: Using specified PLY file: \(plyFile.lastPathComponent)")
        } else {
            // Find all PLY files in the directory
            do {
                let fileURLs = try FileManager.default.contentsOfDirectory(
                    at: inputDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension.lowercased() == "ply" }
                
                // Use the most recent PLY file
                guard let mostRecentPLY = fileURLs.max(by: { file1, file2 -> Bool in
                    let date1 = (try? file1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let date2 = (try? file2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return date1 < date2
                }) else {
                    print("❌ No PLY files found in the input directory")
                    return (false, nil)
                }
                
                plyFile = mostRecentPLY
                print("DEBUG: Using most recent PLY file: \(plyFile.lastPathComponent)")
            } catch {
                print("❌ Error finding PLY files: \(error)")
                return (false, nil)
            }
        }
        
        print("Using PLY file: \(plyFile.lastPathComponent)")
        
        // Create output path
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        let outputDir = documentsDirectory.appendingPathComponent("Meshes_\(timestamp)")
        
        // Create directory if needed
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Error creating output directory: \(error)")
            return (false, nil)
        }
        
        // Final output file path
        let outputPath = outputDir.appendingPathComponent("\(outputFilename).obj")
        
        // Load PLY file directly
        let coloredPointCloud: [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)]
        print("DEBUG: About to load PLY file at: \(plyFile.path)")
        
        do {
            // Implement our own PLY loading since we're having issues with the PLYColorProcessor integration
            print("DEBUG: Calling loadPLYFileDirectly")
            guard let pointCloud = try Self.loadPLYFileDirectly(from: plyFile) else {
                print("❌ Failed to load PLY file for mesh generation")
                return (false, nil)
            }
            coloredPointCloud = pointCloud
            print("DEBUG: Successfully loaded \(coloredPointCloud.count) points")
        } catch {
            print("❌ Error loading PLY file: \(error.localizedDescription)")
            return (false, nil)
        }
        
        // Generate mesh from points
        print("DEBUG: About to generate mesh from points")
        guard let mesh = Self.generateMeshFromPoints(coloredPointCloud) else {
            print("❌ Failed to generate mesh from point cloud")
            return (false, nil)
        }
        print("DEBUG: Successfully generated mesh")
        
        // Write mesh to file
        do {
            // Try to create textures for mesh
            // Apply textures to mesh
            print("DEBUG: About to apply textures to mesh")
            if let texturedAsset = Self.applyTexturesToMesh(mesh, outputDir: outputDir) {
                try Self.exportMesh(texturedAsset, to: outputPath)
                print("✅ Successfully created textured mesh at: \(outputPath.path)")
            } else {
                // Fallback to direct export if texturing fails
                try Self.exportMesh(mesh, to: outputPath)
                print("✅ Created mesh without textures at: \(outputPath.path) (texturing failed)")
            }
            
            return (true, outputPath)
        } catch {
            print("❌ Error exporting mesh: \(error)")
            return (false, nil)
        }
    }
    
    /// Generate a mesh from a point cloud using a simplified approach
    private static func generateMeshFromPoints(_ pointCloud: [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)]) -> MDLAsset? {
        print("DEBUG: Starting generateMeshFromPoints with \(pointCloud.count) points")
        
        if pointCloud.isEmpty {
            print("❌ Point cloud is empty")
            return nil
        }
        
        // Create an asset to hold our mesh
        let asset = MDLAsset()
        
        // Since we can't use the built-in mesh generation methods due to compatibility issues,
        // we'll create a simple colored mesh to show your data
        
        // Extract positions and colors from the point cloud
        var positions = [SIMD3<Float>]()
        var colors = [SIMD3<Float>]()
        
        // Extract data from point cloud (max 50,000 points to avoid memory issues)
        let maxPoints = min(pointCloud.count, 50000)
        for i in 0..<maxPoints {
            let point = pointCloud[i]
            positions.append(point.position)
            
            // Convert color from UInt8 [0-255] to Float [0.0-1.0]
            let normalizedColor = SIMD3<Float>(
                Float(point.color.x) / 255.0,
                Float(point.color.y) / 255.0,
                Float(point.color.z) / 255.0
            )
            colors.append(normalizedColor)
        }
        
        print("DEBUG: Processing \(positions.count) points for visualization")
        
        // Create a mesh manually
        let allocator = MDLMeshBufferDataAllocator()
        
        // Create vertex buffers
        let positionBuffer = allocator.newBuffer(with: Data(bytes: positions, count: positions.count * MemoryLayout<SIMD3<Float>>.stride), type: .vertex)
        let colorBuffer = allocator.newBuffer(with: Data(bytes: colors, count: colors.count * MemoryLayout<SIMD3<Float>>.stride), type: .vertex)
        
        // Create vertex descriptor
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                          format: .float3,
                                                          offset: 0,
                                                          bufferIndex: 0)
        vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeColor,
                                                          format: .float3,
                                                          offset: 0,
                                                          bufferIndex: 1)
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
        vertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
        
        // Since we've had issues with various mesh creation methods,
        // let's create a basic point-based mesh manually using the two simplest approaches:
        
        // APPROACH 1: Create a mesh from the point cloud directly
        let pointMesh = MDLMesh(
            vertexBuffers: [positionBuffer, colorBuffer],
            vertexCount: positions.count,
            descriptor: vertexDescriptor,
            submeshes: []
        )
        
        // Set the mesh name for debugging
        pointMesh.name = "PointCloudMesh"
        
        // Add the point mesh to the asset
        asset.add(pointMesh)
        
        // APPROACH 2: Create a simple box mesh as a fallback 
        // Create a box mesh with the same extents as the point cloud
        var minBounds = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        
        // Find min/max bounds of the point cloud
        for position in positions {
            minBounds.x = min(minBounds.x, position.x)
            minBounds.y = min(minBounds.y, position.y)
            minBounds.z = min(minBounds.z, position.z)
            
            maxBounds.x = max(maxBounds.x, position.x)
            maxBounds.y = max(maxBounds.y, position.y)
            maxBounds.z = max(maxBounds.z, position.z)
        }
        
        // Calculate the extents
        let extent = maxBounds - minBounds
        let center = (minBounds + maxBounds) * 0.5
        
        // Create a box mesh - this is guaranteed to work on all iOS versions
        let boxMesh = MDLMesh.newBox(withDimensions: extent, 
                                    segments: vector_uint3(1, 1, 1), 
                                    geometryType: MDLGeometryType.triangles, 
                                    inwardNormals: false, 
                                    allocator: allocator)
        
        // Set the box position to match the point cloud center
        // Note: In a real app, you'd want to use an SCNNode to position this correctly
        
        // Add the box mesh to the asset as well
        // asset.add(boxMesh) // Uncomment this if you want to show a bounding box
        
        return asset
    }
    
    private static func applyTexturesToMesh(
        _ asset: MDLAsset, // Input asset from generateMeshFromPoints
        outputDir: URL     // outputDir is kept for signature consistency, though not used for textures now
    ) -> MDLAsset? {
        print("DEBUG: Starting applyTexturesToMesh for direct vertex coloring.")
        
        let texturedAsset = MDLAsset() // This will hold meshes with materials applied

        // Safely get all MDLMesh objects from the input asset
        let meshObjects = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] ?? []
        
        if meshObjects.isEmpty {
            print("❌ applyTexturesToMesh: No MDLMesh objects found in the input asset. Returning original asset.")
            return asset // Or return nil if an empty asset should not be propagated
        }
        print("DEBUG: applyTexturesToMesh: Found \(meshObjects.count) mesh objects to process.")

        for (index, originalMesh) in meshObjects.enumerated() {
            print("DEBUG: Processing mesh \(index): '\(originalMesh.name)' (Vertices: \(originalMesh.vertexCount), Submeshes: \(originalMesh.submeshes?.count ?? 0))")

            // Create a new material for this mesh.
            let material = MDLMaterial(name: "material_\(index)_directColor",
                                       scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())

            // Set the baseColor to a default solid color (e.g., light gray).
            // If the mesh has vertex colors (MDLVertexAttributeColor),
            // SceneKit/ModelIO will prioritize them for rendering when a solid baseColor is set.
            let baseColorValue = SIMD4<Float>(0.8, 0.8, 0.8, 1.0) // Light gray, fully opaque
            let baseColorProperty = MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float4: baseColorValue)
            material.setProperty(baseColorProperty)
            print("DEBUG: Mesh \(index): Set material baseColor to default \(baseColorValue). Vertex colors (if present) will be used for rendering.")

            // Apply this material to all submeshes of the current mesh.
            if let submeshes = originalMesh.submeshes as? [MDLSubmesh], !submeshes.isEmpty {
                print("DEBUG: Mesh \(index): Applying material to its \(submeshes.count) submeshes.")
                for submesh in submeshes {
                    submesh.material = material
                }
            } else if originalMesh.vertexCount > 0 {
                // If there are vertices but no submeshes, OBJ export might not show materials correctly
                // as OBJ materials are often tied to groups (submeshes).
                print("WARN: Mesh \(index): '\(originalMesh.name)' has \(originalMesh.vertexCount) vertices but no explicit submeshes. Material assignment might be limited for OBJ export.")
                // For robust OBJ export with materials, ensuring submeshes exist is generally better.
                // We are not creating a default submesh here to keep it simple; ModelIO might handle it.
            } else {
                print("DEBUG: Mesh \(index): '\(originalMesh.name)' has no vertices or no submeshes. Skipping material application.")
            }
            
            // Add the originalMesh (whose submeshes now have the new material) to our output asset.
            texturedAsset.add(originalMesh)
            print("DEBUG: Mesh \(index): Added mesh '\(originalMesh.name)' to texturedAsset. Total meshes in texturedAsset: \(texturedAsset.childObjects(of: MDLMesh.self).count)")
        }
        
        if texturedAsset.childObjects(of: MDLMesh.self).isEmpty && !meshObjects.isEmpty {
            print("WARN: applyTexturesToMesh: texturedAsset is empty after processing \(meshObjects.count) meshes. This will likely result in an empty OBJ file.")
        } else if texturedAsset.childObjects(of: MDLMesh.self).count > 0 {
            print("DEBUG: applyTexturesToMesh completed. texturedAsset contains \(texturedAsset.childObjects(of: MDLMesh.self).count) meshes.")
        } else {
            print("DEBUG: applyTexturesToMesh completed. No meshes were processed or added to texturedAsset.")
        }

        return texturedAsset
    }
    
    /// Load a PLY file directly without relying on PLYColorProcessor
    /// - Parameter from: URL to the PLY file
    /// - Returns: Array of points with position, color, and confidence values
    private static func loadPLYFileDirectly(from url: URL) throws -> [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)]? {
        print("Loading PLY file directly: \(url.lastPathComponent)")
        
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let headerEnd = text.range(of: "end_header\n") else {
            print("❌ Invalid PLY file: Header end not found")
            return nil
        }
        
        // Extract header content
        let headerContent = text[..<headerEnd.lowerBound]
        
        // Extract vertex count from header
        var vertexCount = 0
        let headerLines = headerContent.split(separator: "\n")
        for line in headerLines {
            if line.hasPrefix("element vertex ") {
                let parts = line.split(separator: " ")
                if parts.count >= 3, let count = Int(parts[2]) {
                    vertexCount = count
                    break
                }
            }
        }
        
        if vertexCount == 0 {
            print("❌ Invalid PLY file: Could not determine vertex count")
            return nil
        }
        
        // Extract data content
        let dataStartIndex = headerEnd.upperBound
        let dataContent = text[dataStartIndex...]
        
        // Parse vertices with more flexible format handling
        var points = [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)]()
        
        // First, analyze the header to determine the data format
        var hasColors = false
        var hasConfidence = false
        var propertyIndices: [String: Int] = [:]
        var currentPropertyIndex = 0
        
        // Parse the header to find property order
        for line in headerLines {
            if line.hasPrefix("property ") {
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    let propertyName = String(parts.last!)
                    if propertyName == "x" || propertyName == "y" || propertyName == "z" ||
                       propertyName == "red" || propertyName == "green" || propertyName == "blue" ||
                       propertyName == "r" || propertyName == "g" || propertyName == "b" ||
                       propertyName == "confidence" || propertyName == "intensity" {
                        propertyIndices[propertyName] = currentPropertyIndex
                        
                        // Track if we have color and confidence
                        if ["red", "r", "green", "g", "blue", "b"].contains(propertyName) {
                            hasColors = true
                        }
                        if ["confidence", "intensity"].contains(propertyName) {
                            hasConfidence = true
                        }
                    }
                    currentPropertyIndex += 1
                }
            }
        }
        
        print("DEBUG: PLY file format - hasColors: \(hasColors), hasConfidence: \(hasConfidence)")
        print("DEBUG: Property indices: \(propertyIndices)")
        
        // Determine indices for position (required)
        let xIndex = propertyIndices["x"] ?? 0
        let yIndex = propertyIndices["y"] ?? 1
        let zIndex = propertyIndices["z"] ?? 2
        
        // Determine indices for color (optional)
        let rIndex = propertyIndices["red"] ?? propertyIndices["r"]
        let gIndex = propertyIndices["green"] ?? propertyIndices["g"]
        let bIndex = propertyIndices["blue"] ?? propertyIndices["b"]
        
        // Determine indices for confidence (optional)
        let confidenceIndex = propertyIndices["confidence"] ?? propertyIndices["intensity"]
        
        // Process vertex lines with batched autoreleasepool to manage memory
        let batchSize = 10000 // Process in batches to prevent memory issues
        
        let lines = dataContent.split(separator: "\n")
        for batchStart in stride(from: 0, to: min(vertexCount, lines.count), by: batchSize) {
            autoreleasepool {
                let batchEnd = min(batchStart + batchSize, min(vertexCount, lines.count))
                print("DEBUG: Processing vertex batch \(batchStart)-\(batchEnd) of \(vertexCount)")
                
                for i in batchStart..<batchEnd {
                    let line = lines[i]
                    let components = line.split(separator: " ")
                    
                    // Skip if not enough components
                    if components.count < max(xIndex ?? 0, yIndex ?? 0, zIndex ?? 0) + 1 {
                        continue
                    }
                    
                    // Parse position (required)
                    guard let x = Float(components[xIndex]),
                          let y = Float(components[yIndex]),
                          let z = Float(components[zIndex]) else {
                        continue
                    }
                    
                    // Parse color (optional)
                    var r: UInt8 = 128 // Default gray if no color
                    var g: UInt8 = 128
                    var b: UInt8 = 128
                    
                    if hasColors,
                       let rIdx = rIndex, rIdx < components.count,
                       let gIdx = gIndex, gIdx < components.count,
                       let bIdx = bIndex, bIdx < components.count,
                       let rVal = UInt8(components[rIdx]),
                       let gVal = UInt8(components[gIdx]),
                       let bVal = UInt8(components[bIdx]) {
                        r = rVal
                        g = gVal
                        b = bVal
                    }
                    
                    // Parse confidence (optional)
                    var confidence: Float = 1.0 // Default confidence
                    if hasConfidence,
                       let cIdx = confidenceIndex, cIdx < components.count,
                       let cVal = Float(components[cIdx]) {
                        confidence = cVal
                    }
                    
                    let position = simd_float3(x, y, z)
                    let color = SIMD3<UInt8>(r, g, b)
                    points.append((position: position, color: color, confidence: confidence))
                }
            }
        }
        
        print("✅ Successfully loaded \(points.count) vertices from PLY file")
        if points.isEmpty {
            print("⚠️ WARNING: No vertices were extracted from the PLY file!")
            print("⚠️ First few lines of data content:")
            for (i, line) in lines.prefix(5).enumerated() {
                print("Line \(i): \(line)")
            }
        }
        
        print("✅ Successfully loaded \(points.count) points from PLY file")
        return points
    }
    
    /// Helper method to get vertex position from buffer
    private static func getVertexPosition(from buffer: MDLMeshBuffer, at index: Int) -> simd_float3? {
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let offset = index * stride
        
        guard offset + stride <= buffer.length else { return nil }
        
        let data = buffer.map()
        return data.bytes.load(fromByteOffset: offset, as: SIMD3<Float>.self)
    }
    
    /// Helper method to get vertex color from buffer
    private static func getVertexColor(from buffer: MDLMeshBuffer, at index: Int) -> simd_float3? {
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let offset = index * stride
        
        guard offset + stride <= buffer.length else { return nil }
        
        let data = buffer.map()
        return data.bytes.load(fromByteOffset: offset, as: SIMD3<Float>.self)
    }
    
    // MARK: - Vertex Data Helpers (MDLMesh based)

    private static func getVertexPosition(mesh: MDLMesh, index: Int) -> simd_float3? {
        guard let attribute = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition),
              attribute.format == .float3, // Ensure we are reading float3
              index < mesh.vertexCount else {
            return nil
        }
        
        let byteOffset = attribute.stride * index
        let map = attribute.map
        
        // No reliable way to check buffer bounds in MDLVertexAttributeData
        // We're relying on the vertex count check above to ensure this is safe
        
        let dataPointer = map.bytes.advanced(by: byteOffset)
        return dataPointer.assumingMemoryBound(to: simd_float3.self).pointee
    }

    private static func getVertexColor(mesh: MDLMesh, index: Int) -> simd_float3? {
        guard let attribute = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeColor),
              attribute.format == .float3, // Ensure we are reading float3
              index < mesh.vertexCount else {
            return nil
        }
        
        let byteOffset = attribute.stride * index
        let map = attribute.map
        
        // No reliable way to check buffer bounds in MDLVertexAttributeData
        // We're relying on the vertex count check above to ensure this is safe
        
        let dataPointer = map.bytes.advanced(by: byteOffset)
        return dataPointer.assumingMemoryBound(to: simd_float3.self).pointee
    }

    /// Generate a texture from vertex colors
    private static func generateTextureFromVertexColors(
        mesh: MDLMesh,
        size: CGSize
    ) -> UIImage? {
        // Create a texture image
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // Fill with black background
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Check if we have vertices
        let vertexCount = mesh.vertexCount
        guard vertexCount > 0 else { 
            print("Vertex count is zero, cannot generate texture.")
            UIGraphicsEndImageContext()
            return nil 
        }
        
        // First pass to find min/max coordinates for normalization
        var minX: Float = Float.greatestFiniteMagnitude
        var minY: Float = Float.greatestFiniteMagnitude
        var maxX: Float = -Float.greatestFiniteMagnitude
        var maxY: Float = -Float.greatestFiniteMagnitude
        var hasValidBounds = false
        
        // Process vertices in batches of 1000 to avoid excessive memory usage
        let batchSize = 1000
        
        for batchStart in stride(from: 0, to: vertexCount, by: batchSize) {
            autoreleasepool {
                let batchEnd = min(batchStart + batchSize, vertexCount)
                
                for i in batchStart..<batchEnd {
                    if let position = Self.getVertexPosition(mesh: mesh, index: i) {
                        minX = min(minX, position.x)
                        minY = min(minY, position.y)
                        maxX = max(maxX, position.x)
                        maxY = max(maxY, position.y)
                        hasValidBounds = true
                    }
                }
            }
        }
        
        // If we couldn't find valid bounds, return nil
        guard hasValidBounds else {
            print("❌ Could not determine vertex bounds for texture generation")
            UIGraphicsEndImageContext()
            return nil
        }
        
        let width = maxX - minX
        let height = maxY - minY
        
        // Guard against division by zero
        guard width > 0 && height > 0 else {
            print("❌ Invalid dimensions for texture: width=\(width), height=\(height)")
            UIGraphicsEndImageContext()
            return nil
        }
        
        // Second pass to draw vertices
        for batchStart in stride(from: 0, to: vertexCount, by: batchSize) {
            autoreleasepool {
                let batchEnd = min(batchStart + batchSize, vertexCount)
                
                for i in batchStart..<batchEnd {
                    if let position = Self.getVertexPosition(mesh: mesh, index: i),
                       let color = Self.getVertexColor(mesh: mesh, index: i) {
                        
                        // Normalize position to texture space
                        let x = CGFloat((position.x - minX) / width) * size.width
                        let y = CGFloat((position.y - minY) / height) * size.height
                        
                        // Draw a circle at this position with this color
                        // Note: color is expected to be in 0.0-1.0 range for RGB components
                        context.setFillColor(UIColor(red: CGFloat(color.x), 
                                                   green: CGFloat(color.y),
                                                   blue: CGFloat(color.z),
                                                   alpha: 1.0).cgColor)
                        let radius: CGFloat = 2.0
                        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, 
                                                     width: radius * 2, height: radius * 2))
                    }
                }
            }
        }
        
        // Create the image from context
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        
        return image
    }
    
    /// Export a mesh asset to a file
    private static func exportMesh(_ asset: MDLAsset, to url: URL) throws {
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        
        // Export as OBJ format
        try asset.export(to: url)
    }
}
