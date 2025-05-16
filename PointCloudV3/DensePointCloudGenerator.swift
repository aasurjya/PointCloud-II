// DensePointCloudGenerator.swift
// PointCloudV3
// Created on 16/05/25
// Generates dense, high-quality point clouds based on research techniques

import Foundation
import ARKit
import simd

// MARK: - Point Cloud Generation Configuration

struct PointCloudConfig {
    // Vertex density configuration
    let enableSubdivision: Bool = true
    let adaptiveSubdivisionThreshold: Float = 0.02 // in meters
    let maxSubdivisionLevel: Int = 2
    
    // Color mapping configuration
    let multiFrameBlending: Bool = true
    let blendFrameCount: Int = 3
    let spatialWeightFactor: Float = 2.0
    
    // Processing configuration
    let batchSize: Int = 5000 // Process this many vertices at once
    let enableProgressiveOutput: Bool = true
    let filterOutliers: Bool = true
    let outlierThreshold: Float = 2.0 // Standard deviations
}

// MARK: - Dense Point Cloud Generator

class DensePointCloudGenerator {
    // Configuration
    private let config: PointCloudConfig
    
    // Callback for progress updates
    private var progressCallback: ((String, Double) -> Void)?
    
    // Processing state
    private var totalVerticesProcessed: Int = 0
    private var defaultColorCount: Int = 0
    private var enhancedColorCount: Int = 0
    
    init(config: PointCloudConfig = PointCloudConfig()) {
        self.config = config
    }
    
    /// Set a callback for progress updates
    func setProgressCallback(_ callback: @escaping (String, Double) -> Void) {
        self.progressCallback = callback
    }
    
    /// Generate a dense point cloud from mesh anchors and frames
    func generatePointCloud(
        meshAnchors: [ARMeshAnchor], 
        frames: [CapturedFrame], 
        outputURL: URL
    ) async -> Bool {
        // Reset counters
        totalVerticesProcessed = 0
        defaultColorCount = 0
        enhancedColorCount = 0
        
        updateProgress("Starting point cloud generation", 0.0)
        
        guard !meshAnchors.isEmpty else {
            updateProgress("Error: No mesh anchors available", 0.0)
            return false
        }
        
        guard !frames.isEmpty else {
            updateProgress("Error: No frames available for texturing", 0.0)
            return false
        }
        
        // Create an index to search frames by timestamp
        let sortedFrames = frames.sorted { $0.timestamp < $1.timestamp }
        
        // Initialize PLY file with header (will be rewritten at the end with correct vertex count)
        let initialVertexEstimate = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }
        initializePLYFile(url: outputURL, estimatedVertexCount: initialVertexEstimate)
        
        // Track total vertices for file finalization
        var totalVerticesWritten = 0
        var totalConfidenceSum: Float = 0
        
        // Process each mesh anchor and stream to file
        for (anchorIndex, anchor) in meshAnchors.enumerated() {
            let progress = Double(anchorIndex) / Double(meshAnchors.count)
            updateProgress("Processing anchor \(anchorIndex + 1)/\(meshAnchors.count)", progress)
            
            // Process anchor and write vertices directly to file
            let vertexCountWritten = await processAnchorAndStreamToDisk(anchor, 
                                                 sortedFrames: sortedFrames, 
                                                 outputURL: outputURL, 
                                                 totalVerticesSoFar: totalVerticesWritten)
            
            // Use autoreleasepool after async operation to clean up
            autoreleasepool {
                // Force cleanup of any temporary objects
            }
            
            // Save vertex count
            let anchorVertexCount = vertexCountWritten
            
            // Update the vertex count
            totalVerticesWritten += anchorVertexCount
            
            // Update progress
            let partialProgress = Double(anchorIndex) / Double(meshAnchors.count)
            updateProgress("Processed anchor \(anchorIndex + 1)/\(meshAnchors.count) - \(totalVerticesWritten) points so far", partialProgress)
        }
        
        updateProgress("Finalizing point cloud file", 0.9)
        
        // Finalize the PLY file with the correct vertex count
        let success = finalizePLYFile(url: outputURL, actualVertexCount: totalVerticesWritten)
        
        updateProgress("Export complete: \(totalVerticesWritten) points", 1.0)
        
        return success
    }
    
    /// Process a single mesh anchor
    private func processAnchor(_ anchor: ARMeshAnchor, sortedFrames: [CapturedFrame]) async -> [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)] {
        // Extract vertices and faces from the anchor
        let (localVertices, vertexNormals) = extractVerticesAndNormals(from: anchor)
        
        var verticesWithColor = [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)]()
        
        // Create batches for processing to avoid blocking the UI
        let batchSize = config.batchSize
        let batches = (localVertices.count + batchSize - 1) / batchSize
        
        for batchIndex in 0..<batches {
            let start = batchIndex * batchSize
            let end = min(start + batchSize, localVertices.count)
            
            for i in start..<end {
                guard i < localVertices.count else { continue }
                
                let localVertex = localVertices[i]
                let localNormal = (i < vertexNormals.count && length_squared(vertexNormals[i]) > .ulpOfOne) ? vertexNormals[i] : nil
                
                // Transform to world space
                let worldVertex4 = anchor.transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
                let worldVertex = SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z) / worldVertex4.w
                
                // Transform normal to world space
                var worldNormal: SIMD3<Float>? = nil
                if let ln = localNormal {
                    let rotationMatrix = simd_float3x3(columns: (
                        anchor.transform.columns.0.xyz,
                        anchor.transform.columns.1.xyz,
                        anchor.transform.columns.2.xyz
                    ))
                    if length_squared(ln) > .ulpOfOne {
                        worldNormal = normalize(rotationMatrix * ln)
                    }
                }
                
                // For denser point cloud, subdivide if needed
                if config.enableSubdivision {
                    let subdivided = subdivideVertexIfNeeded(worldVertex, normal: worldNormal, localVertex: localVertex, anchor: anchor)
                    
                    for subVertex in subdivided {
                        let (color, confidence) = enhancedSampleColor(point: subVertex.position, normal: subVertex.normal, frames: sortedFrames)
                        verticesWithColor.append((position: subVertex.position, color: color, confidence: confidence))
                    }
                } else {
                    // No subdivision - just process the vertex directly
                    let (color, confidence) = enhancedSampleColor(point: worldVertex, normal: worldNormal, frames: sortedFrames)
                    verticesWithColor.append((position: worldVertex, color: color, confidence: confidence))
                }
                
                totalVerticesProcessed += 1
            }
            
            // Yield to the main thread periodically
            if batchIndex % 5 == 0 {
                await Task.yield()
            }
        }
        
        return verticesWithColor
    }
    
    /// Extract vertices and compute normals from a mesh anchor
    private func extractVerticesAndNormals(from anchor: ARMeshAnchor) -> ([SIMD3<Float>], [SIMD3<Float>]) {
        let geometry = anchor.geometry
        
        // Extract vertices
        let vertices = geometry.vertices
        let verticesBuffer = vertices.buffer.contents()
        let verticesOffset = vertices.offset
        let verticesStride = vertices.stride
        var localVertices = [SIMD3<Float>]()
        for i in 0..<vertices.count {
            let vertexPointer = verticesBuffer.advanced(by: verticesOffset + i * verticesStride)
            localVertices.append(vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
        }
        
        // Extract faces
        let faces = geometry.faces
        let facesBuffer = faces.buffer.contents()
        let indicesPerFace = faces.indexCountPerPrimitive
        var parsedFaces = [[Int]]()
        
        if faces.bytesPerIndex == 4 {
            for i in 0..<faces.count {
                var faceIndices = [Int]()
                for j in 0..<indicesPerFace {
                    let byteOffset = (i * indicesPerFace + j) * MemoryLayout<UInt32>.size
                    let indexPointer = facesBuffer.advanced(by: byteOffset)
                    faceIndices.append(Int(indexPointer.assumingMemoryBound(to: UInt32.self).pointee))
                }
                parsedFaces.append(faceIndices)
            }
        } else if faces.bytesPerIndex == 2 {
            for i in 0..<faces.count {
                var faceIndices = [Int]()
                for j in 0..<indicesPerFace {
                    let byteOffset = (i * indicesPerFace + j) * MemoryLayout<UInt16>.size
                    let indexPointer = facesBuffer.advanced(by: byteOffset)
                    faceIndices.append(Int(indexPointer.assumingMemoryBound(to: UInt16.self).pointee))
                }
                parsedFaces.append(faceIndices)
            }
        }
        
        // Compute vertex normals
        var vertexNormals = [SIMD3<Float>](repeating: .zero, count: localVertices.count)
        if !parsedFaces.isEmpty && !localVertices.isEmpty {
            for face in parsedFaces {
                guard face.count == 3,
                      face[0] < localVertices.count,
                      face[1] < localVertices.count,
                      face[2] < localVertices.count else { continue }
                
                let v0 = localVertices[face[0]]
                let v1 = localVertices[face[1]]
                let v2 = localVertices[face[2]]
                let faceNormal = normalize(cross(v1 - v0, v2 - v0))
                
                vertexNormals[face[0]] += faceNormal
                vertexNormals[face[1]] += faceNormal
                vertexNormals[face[2]] += faceNormal
            }
            
            // Normalize the accumulated face normals
            for i in 0..<vertexNormals.count {
                if length_squared(vertexNormals[i]) > .ulpOfOne {
                    vertexNormals[i] = normalize(vertexNormals[i])
                }
            }
        }
        
        return (localVertices, vertexNormals)
    }
    
    /// Subdivide a vertex to create a denser point cloud
    private func subdivideVertexIfNeeded(
        _ vertex: SIMD3<Float>,
        normal: SIMD3<Float>?,
        localVertex: SIMD3<Float>,
        anchor: ARMeshAnchor,
        level: Int = 0
    ) -> [(position: SIMD3<Float>, normal: SIMD3<Float>?)] {
        // Don't subdivide beyond max level
        if level >= config.maxSubdivisionLevel {
            return [(position: vertex, normal: normal)]
        }
        
        // Create subdivided points
        let jitterScale: Float = 0.005 / Float(level + 1) // Smaller subdivisions at deeper levels
        
        var result = [(position: vertex, normal: normal)]
        
        // Add additional points with small offsets
        for _ in 0..<(4 / (level + 1)) { // Fewer subdivisions at deeper levels
            let jitter = SIMD3<Float>(
                Float.random(in: -jitterScale...jitterScale),
                Float.random(in: -jitterScale...jitterScale),
                Float.random(in: -jitterScale...jitterScale)
            )
            
            let newPos = vertex + jitter
            result.append((position: newPos, normal: normal))
        }
        
        return result
    }
    
    /// Enhanced color sampling using multiple frames and quality-based weighting
    private func enhancedSampleColor(
        point: SIMD3<Float>,
        normal: SIMD3<Float>?,
        frames: [CapturedFrame]
    ) -> (color: SIMD3<UInt8>, confidence: Float) {
        // If no blending, use the original approach with the best frame
        if !config.multiFrameBlending {
            if let bestFrame = findBestFrame(for: point, normal: normal, in: frames) {
                let color = sampleColor(worldPoint: point, frame: bestFrame)
                return (color: color, confidence: 1.0)
            } else {
                defaultColorCount += 1
                return (color: SIMD3<UInt8>(128, 128, 128), confidence: 0.0)
            }
        }
        
        // Multi-frame blending approach
        let bestFrames = findTopFrames(for: point, normal: normal, in: frames, count: config.blendFrameCount)
        
        guard !bestFrames.isEmpty else {
            defaultColorCount += 1
            return (color: SIMD3<UInt8>(128, 128, 128), confidence: 0.0)
        }
        
        if bestFrames.count == 1 {
            let color = sampleColor(worldPoint: point, frame: bestFrames[0].frame)
            return (color: color, confidence: bestFrames[0].score)
        }
        
        // Blend colors from multiple frames
        var totalWeight: Float = 0.0
        var weightedR: Float = 0.0
        var weightedG: Float = 0.0
        var weightedB: Float = 0.0
        var highestConfidence: Float = 0.0
        
        for frameData in bestFrames {
            let frame = frameData.frame
            let weight = frameData.score
            totalWeight += weight
            
            let color = sampleColor(worldPoint: point, frame: frame)
            weightedR += Float(color.x) * weight
            weightedG += Float(color.y) * weight
            weightedB += Float(color.z) * weight
            
            highestConfidence = max(highestConfidence, weight)
        }
        
        // Normalize by total weight
        if totalWeight > 0 {
            weightedR /= totalWeight
            weightedG /= totalWeight
            weightedB /= totalWeight
        }
        
        enhancedColorCount += 1
        
        return (
            color: SIMD3<UInt8>(
                UInt8(clamping: Int(round(weightedR))),
                UInt8(clamping: Int(round(weightedG))),
                UInt8(clamping: Int(round(weightedB)))
            ),
            confidence: highestConfidence
        )
    }
    
    /// Find the best frame for a point
    private func findBestFrame(for point: SIMD3<Float>, normal: SIMD3<Float>?, in frames: [CapturedFrame]) -> CapturedFrame? {
        guard !frames.isEmpty else { return nil }
        if frames.count == 1 { return frames.first }
        
        var bestScore: Float = -Float.greatestFiniteMagnitude
        var bestFrame: CapturedFrame? = nil
        
        for frame in frames {
            let score = scoreFrameForPoint(point, normal: normal, frame: frame)
            if score > bestScore {
                bestScore = score
                bestFrame = frame
            }
        }
        
        return bestFrame
    }
    
    /// Find the top N frames for a point with their scores
    private func findTopFrames(
        for point: SIMD3<Float>,
        normal: SIMD3<Float>?,
        in frames: [CapturedFrame],
        count: Int
    ) -> [(frame: CapturedFrame, score: Float)] {
        guard !frames.isEmpty else { return [] }
        if frames.count == 1 { return [(frame: frames[0], score: 1.0)] }
        
        var scoredFrames = [(frame: CapturedFrame, score: Float)]()
        
        for frame in frames {
            let score = scoreFrameForPoint(point, normal: normal, frame: frame)
            if score > 0.01 { // Only consider frames with meaningful scores
                scoredFrames.append((frame: frame, score: score))
            }
        }
        
        // Sort by score and take top N
        scoredFrames.sort { $0.score > $1.score }
        return Array(scoredFrames.prefix(count))
    }
    
    /// Score a frame for a specific point using multiple factors
    private func scoreFrameForPoint(_ point: SIMD3<Float>, normal: SIMD3<Float>?, frame: CapturedFrame) -> Float {
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        // Vector from point to camera
        let pointToCamera = normalize(cameraPosition - point)
        
        // Base score inversely proportional to distance
        let dist = distance(cameraPosition, point)
        var score: Float = 1.0 / (dist + 0.01) * config.spatialWeightFactor
        
        // Favor views where normal points toward camera
        if let normal = normal {
            let alignment = dot(pointToCamera, normal)
            score *= max(0.1, alignment)
        }
        
        // Check if point is visible in the frame (within camera frustum)
        let imageWidthCG = CGFloat(frame.image.width)
        let imageHeightCG = CGFloat(frame.image.height)
        
        let projectedPoint = frame.camera.projectPoint(
            point,
            orientation: .landscapeRight,
            viewportSize: CGSize(width: imageWidthCG, height: imageHeightCG)
        )
        
        if projectedPoint.x < 0 || projectedPoint.y < 0 ||
           projectedPoint.x >= imageWidthCG || projectedPoint.y >= imageHeightCG {
            // Point is outside of frame
            score *= 0.05
        } else {
            // Favor points closer to center of frame
            let projectedX_Float = Float(projectedPoint.x)
            let projectedY_Float = Float(projectedPoint.y)
            let imageWidth_Float = Float(imageWidthCG)
            let imageHeight_Float = Float(imageHeightCG)
            
            let dx = projectedX_Float - imageWidth_Float / 2
            let dy = projectedY_Float - imageHeight_Float / 2
            let centerDist = sqrt(dx*dx + dy*dy)
            
            // Reduce score based on distance from center
            score *= (1.0 - min(0.5, centerDist / (max(imageWidth_Float, imageHeight_Float))))
        }
        
        return max(0.0, score)
    }
    
    /// Sample color from a frame
    private func sampleColor(worldPoint: SIMD3<Float>, frame: CapturedFrame) -> SIMD3<UInt8> {
        let camera = frame.camera
        let imageWidthCG = CGFloat(frame.image.width)
        let imageHeightCG = CGFloat(frame.image.height)
        
        let projectedPt = camera.projectPoint(
            worldPoint,
            orientation: .landscapeRight,
            viewportSize: CGSize(width: imageWidthCG, height: imageHeightCG)
        )
        
        // Check if point is behind the camera
        let pointInCameraSpace = camera.transform.inverse * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        if pointInCameraSpace.z >= 0 {
            return SIMD3<UInt8>(128, 128, 128)
        }
        
        // Convert to Float for consistent calculations
        let u_exact = Float(projectedPt.x)
        let v_exact = Float(projectedPt.y)
        
        // Check bounds
        if u_exact < 0 || u_exact >= Float(imageWidthCG) - 1 || v_exact < 0 || v_exact >= Float(imageHeightCG) - 1 {
            return SIMD3<UInt8>(128, 128, 128)
        }
        
        // Get image data
        guard let dataProvider = frame.image.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else {
            return SIMD3<UInt8>(128, 128, 128)
        }
        
        let bytesPerRow = frame.image.bytesPerRow
        let bytesPerPixel = frame.image.bitsPerPixel / 8
        if bytesPerPixel != 4 {
            return SIMD3<UInt8>(100, 100, 100)
        }
        
        // Bilinear interpolation
        let x0 = Int(floor(u_exact))
        let y0 = Int(floor(v_exact))
        
        let u_ratio = u_exact - Float(x0)
        let v_ratio = v_exact - Float(y0)
        let u_opposite = 1 - u_ratio
        let v_opposite = 1 - v_ratio
        
        func getColorComponentAt(x: Int, y: Int, componentOffset: Int) -> Float {
            let offset = y * bytesPerRow + x * bytesPerPixel + componentOffset
            guard offset < CFDataGetLength(data) && offset >= 0 else {
                return 128.0
            }
            return Float(ptr[offset])
        }
        
        // Sample corners
        let r00 = getColorComponentAt(x: x0, y: y0, componentOffset: 0)
        let g00 = getColorComponentAt(x: x0, y: y0, componentOffset: 1)
        let b00 = getColorComponentAt(x: x0, y: y0, componentOffset: 2)
        
        let r10 = getColorComponentAt(x: x0 + 1, y: y0, componentOffset: 0)
        let g10 = getColorComponentAt(x: x0 + 1, y: y0, componentOffset: 1)
        let b10 = getColorComponentAt(x: x0 + 1, y: y0, componentOffset: 2)
        
        let r01 = getColorComponentAt(x: x0, y: y0 + 1, componentOffset: 0)
        let g01 = getColorComponentAt(x: x0, y: y0 + 1, componentOffset: 1)
        let b01 = getColorComponentAt(x: x0, y: y0 + 1, componentOffset: 2)
        
        let r11 = getColorComponentAt(x: x0 + 1, y: y0 + 1, componentOffset: 0)
        let g11 = getColorComponentAt(x: x0 + 1, y: y0 + 1, componentOffset: 1)
        let b11 = getColorComponentAt(x: x0 + 1, y: y0 + 1, componentOffset: 2)
        
        // Interpolate
        let r_top = r00 * u_opposite + r10 * u_ratio
        let r_bottom = r01 * u_opposite + r11 * u_ratio
        let final_r = r_top * v_opposite + r_bottom * v_ratio
        
        let g_top = g00 * u_opposite + g10 * u_ratio
        let g_bottom = g01 * u_opposite + g11 * u_ratio
        let final_g = g_top * v_opposite + g_bottom * v_ratio
        
        let b_top = b00 * u_opposite + b10 * u_ratio
        let b_bottom = b01 * u_opposite + b11 * u_ratio
        let final_b = b_top * v_opposite + b_bottom * v_ratio
        
        return SIMD3<UInt8>(
            UInt8(clamping: Int(round(final_r))),
            UInt8(clamping: Int(round(final_g))),
            UInt8(clamping: Int(round(final_b)))
        )
    }
    
    /// Filter outlier points
    private func filterOutliers(vertices: [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)]) -> [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)] {
        guard vertices.count > 10 else { return vertices }
        
        // Statistical outlier removal based on distance to neighbors
        // Calculate average position
        var avgPos = SIMD3<Float>(0, 0, 0)
        for vertex in vertices {
            avgPos += vertex.position
        }
        avgPos /= Float(vertices.count)
        
        // Calculate standard deviation of distances
        var distanceVariance: Float = 0
        var distances = [Float]()
        
        for vertex in vertices {
            let dist = distance(vertex.position, avgPos)
            distances.append(dist)
            distanceVariance += dist * dist
        }
        distanceVariance /= Float(vertices.count)
        let stdDev = sqrt(distanceVariance)
        
        // Remove points that are too far from the center
        let threshold = stdDev * config.outlierThreshold
        
        return vertices.filter { vertex in
            let dist = distance(vertex.position, avgPos)
            return dist <= threshold
        }
    }
    
    /// Initialize a PLY file with header
    private func initializePLYFile(url: URL, estimatedVertexCount: Int) -> Bool {
        // Create initial PLY header with estimated vertex count
        let plyHeader = """
        ply
        format ascii 1.0
        element vertex \(estimatedVertexCount)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property float confidence
        end_header
        """
        
        do {
            try plyHeader.write(to: url, atomically: true, encoding: .utf8)
            print("✅ Initialized PLY file at \(url.path) with estimated \(estimatedVertexCount) points")
            return true
        } catch {
            print("❌ Error initializing PLY file: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Process a single anchor and stream vertices directly to disk
    private func processAnchorAndStreamToDisk(
        _ anchor: ARMeshAnchor, 
        sortedFrames: [CapturedFrame], 
        outputURL: URL,
        totalVerticesSoFar: Int
    ) async -> Int {
        // Extract vertices and faces from the anchor
        let (localVertices, vertexNormals) = extractVerticesAndNormals(from: anchor)
        
        // Open file handle for appending
        guard let fileHandle = try? FileHandle(forWritingTo: outputURL) else {
            print("❌ Failed to open file handle for writing vertices")
            return 0
        }
        
        // Seek to end of file for appending
        try? fileHandle.seekToEnd()
        
        // Create batches for processing to avoid blocking the UI
        let batchSize = min(config.batchSize, 1000) // Smaller batch size to reduce memory usage
        let batches = (localVertices.count + batchSize - 1) / batchSize
        
        var verticesWritten = 0
        
        // Process in small batches to avoid memory growth
        for batchIndex in 0..<batches {
            let start = batchIndex * batchSize
            let end = min(start + batchSize, localVertices.count)
            
            // Process this batch
            var batchOutput = ""
            
            for i in start..<end {
                guard i < localVertices.count else { continue }
                
                // Get vertex and normal
                let localVertex = localVertices[i]
                let localNormal = (i < vertexNormals.count) ? vertexNormals[i] : nil
                
                // Transform to world space
                let worldVertex4 = anchor.transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
                let worldVertex = SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z) / worldVertex4.w
                
                // Transform normal to world space if available
                var worldNormal: SIMD3<Float>? = nil
                if let ln = localNormal, length_squared(ln) > .ulpOfOne {
                    let rotationMatrix = simd_float3x3(columns: (
                        anchor.transform.columns.0.xyz,
                        anchor.transform.columns.1.xyz,
                        anchor.transform.columns.2.xyz
                    ))
                    worldNormal = normalize(rotationMatrix * ln)
                }
                
                // Skip if vertex is too far away (likely noise)
                if length(worldVertex) > 5.0 {
                    continue
                }
                
                // Sample color and get confidence
                let (color, confidence) = enhancedSampleColor(point: worldVertex, normal: worldNormal, frames: sortedFrames)
                
                // Write vertex to string buffer
                batchOutput += "\n\(worldVertex.x) \(worldVertex.y) \(worldVertex.z) "
                batchOutput += "\(color.x) \(color.y) \(color.z) \(confidence)"
                
                verticesWritten += 1
                totalVerticesProcessed += 1
            }
            
            // Write batch to file
            if !batchOutput.isEmpty {
                try? fileHandle.write(contentsOf: batchOutput.data(using: .utf8) ?? Data())
            }
            
            // Yield to main thread periodically
            if batchIndex % 5 == 0 {
                await Task.yield()
            }
            
            // Explicitly release the batch output string to free memory
            batchOutput = ""
        }
        
        // Close file handle
        try? fileHandle.close()
        
        return verticesWritten
    }
    
    /// Finalize the PLY file by updating the header with correct vertex count
    private func finalizePLYFile(url: URL, actualVertexCount: Int) -> Bool {
        do {
            // Read the file content
            let fileContent = try String(contentsOf: url, encoding: .utf8)
            
            // Find the line with the vertex count
            let lines = fileContent.components(separatedBy: "\n")
            var updatedLines = [String]()
            
            for line in lines {
                if line.contains("element vertex") {
                    // Replace with actual vertex count
                    updatedLines.append("element vertex \(actualVertexCount)")
                } else {
                    updatedLines.append(line)
                }
            }
            
            // Write the updated content back to file
            let updatedContent = updatedLines.joined(separator: "\n")
            try updatedContent.write(to: url, atomically: true, encoding: .utf8)
            
            print("✅ Finalized PLY file with \(actualVertexCount) vertices")
            return true
        } catch {
            print("❌ Error finalizing PLY file: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Export point cloud to PLY format with confidence values (legacy method, kept for compatibility)
    private func exportToPLY(vertices: [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)], to url: URL) -> Bool {
        // Create PLY header
        var plyHeader = """
        ply
        format ascii 1.0
        element vertex \(vertices.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        property float confidence
        end_header
        """
        
        // Create PLY body
        var plyBody = ""
        for vertex in vertices {
            plyBody += "\n\(vertex.position.x) \(vertex.position.y) \(vertex.position.z) \(vertex.color.x) \(vertex.color.y) \(vertex.color.z) \(vertex.confidence)"
        }
        
        let fullPlyContent = plyHeader + plyBody
        
        do {
            try fullPlyContent.write(to: url, atomically: true, encoding: .utf8)
            print("✅ Saved colored point cloud to \(url.lastPathComponent) with \(vertices.count) points.")
            return true
        } catch {
            print("❌ Error writing PLY file: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Update progress with callback
    /// Export point cloud to PLY format without confidence values
    private func exportToPLY(vertices: [(position: SIMD3<Float>, color: SIMD3<UInt8>)], to url: URL) async -> Bool {
        // Create PLY header
        var plyHeader = """
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
        
        // Create PLY body
        var plyBody = ""
        for vertex in vertices {
            plyBody += "\n\(vertex.position.x) \(vertex.position.y) \(vertex.position.z) \(vertex.color.x) \(vertex.color.y) \(vertex.color.z)"
        }
        
        let fullPlyContent = plyHeader + plyBody
        
        do {
            try fullPlyContent.write(to: url, atomically: true, encoding: .utf8)
            print("✅ Saved colored point cloud to \(url.lastPathComponent) with \(vertices.count) points.")
            return true
        } catch {
            print("❌ Error writing PLY file: \(error.localizedDescription)")
            return false
        }
    }
    
    private func updateProgress(_ message: String, _ progress: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.progressCallback?(message, progress)
        }
    }
}
