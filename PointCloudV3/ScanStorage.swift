// ScanStorage.swift
// PointCloudV3
// Created on 16/05/25
// Handles continuous writing of scan data (frames, mesh anchors)

import Foundation
import ARKit
import UIKit
import RealityKit
import simd

// MARK: - Storage Models

/// Metadata for a serialized frame
struct FrameMetadata: Codable {
    let timestamp: TimeInterval
    let index: Int
    let cameraTransform: TransformMatrix
    let intrinsics: CameraIntrinsics
    let imageFilename: String
    
    init(frame: CapturedFrame, index: Int, imageFilename: String) {
        self.timestamp = frame.timestamp
        self.index = index
        self.cameraTransform = TransformMatrix(matrix: frame.camera.transform)
        self.intrinsics = CameraIntrinsics(camera: frame.camera)
        self.imageFilename = imageFilename
    }
}

/// Camera intrinsics for projection
struct CameraIntrinsics: Codable {
    let focalLength: SIMD2<Float>
    let principalPoint: SIMD2<Float>
    let imageResolution: SIMD2<Float>
    
    init(camera: ARCamera) {
        // Extract focal length - first column x and y values
        self.focalLength = SIMD2<Float>(camera.intrinsics.columns.0.x, camera.intrinsics.columns.0.y)
        // Extract principal point - second column x and y values
        self.principalPoint = SIMD2<Float>(camera.intrinsics.columns.1.x, camera.intrinsics.columns.1.y)
        // Convert CGSize to SIMD2<Float>
        self.imageResolution = SIMD2<Float>(Float(camera.imageResolution.width), Float(camera.imageResolution.height))
    }
}

/// Codable representation of a 4x4 transform matrix
struct TransformMatrix: Codable {
    let columns: [SIMD4<Float>]
    
    init(matrix: simd_float4x4) {
        self.columns = [
            matrix.columns.0,
            matrix.columns.1,
            matrix.columns.2,
            matrix.columns.3
        ]
    }
    
    var matrix: simd_float4x4 {
        return simd_float4x4(columns[0], columns[1], columns[2], columns[3])
    }
}

/// Metadata for a serialized mesh anchor
struct MeshAnchorMetadata: Codable {
    let identifier: String
    let timestamp: TimeInterval
    let transform: TransformMatrix
    let filename: String
    let vertexCount: Int
    let faceCount: Int
    
    init(anchor: ARMeshAnchor, timestamp: TimeInterval, filename: String, vertexCount: Int, faceCount: Int) {
        self.identifier = anchor.identifier.uuidString
        self.timestamp = timestamp
        self.transform = TransformMatrix(matrix: anchor.transform)
        self.filename = filename
        self.vertexCount = vertexCount
        self.faceCount = faceCount
    }
}

/// Main metadata for the entire scan
struct ScanMetadata: Codable {
    let scanId: String
    let creationDate: Date
    var lastUpdated: Date // Changed to var so it can be updated
    var frameCount: Int
    var meshAnchorCount: Int
    var status: String // "in-progress", "completed", "error"
    var processingProgress: Double // 0.0 to 1.0
    var errorMessage: String?
    
    // Paths to metadata JSON files
    let framesMetadataFile: String
    let meshAnchorsMetadataFile: String
    
    init(scanId: String) {
        self.scanId = scanId
        self.creationDate = Date()
        self.lastUpdated = Date()
        self.frameCount = 0
        self.meshAnchorCount = 0
        self.status = "in-progress"
        self.processingProgress = 0.0
        self.framesMetadataFile = "frames_metadata.json"
        self.meshAnchorsMetadataFile = "mesh_anchors_metadata.json"
    }
}

/// Main storage class for scan data
class ScanStorage {
    // Current scan directory and metadata
    private var currentScanId: String?
    private var currentScanDirectory: URL?
    private var scanMetadata: ScanMetadata?
    
    // Storage subdirectories
    private var framesDirectory: URL?
    private var meshesDirectory: URL?
    private var pointcloudDirectory: URL?
    
    // Metadata arrays
    private var framesMetadata: [FrameMetadata] = []
    private var meshAnchorsMetadata: [MeshAnchorMetadata] = []
    
    // Counters for filenames
    private var frameCounter = 0
    private var meshAnchorCounter = 0
    
    // Queue for background operations
    private let storageQueue = DispatchQueue(label: "com.pointcloud.storage", qos: .utility)
    
    // MARK: - Initialization and Setup
    
    /// Start a new scan session with unique ID
    func startNewScan() -> String {
        closeCurrentScan()
        
        let newScanId = "Scan_\(Int(Date().timeIntervalSince1970))"
        setupScanDirectories(scanId: newScanId)
        
        return newScanId
    }
    
    /// Setup directories for a new scan
    private func setupScanDirectories(scanId: String) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scanDir = documentsDirectory.appendingPathComponent(scanId)
        
        do {
            // Create main scan directory
            try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
            
            // Create subdirectories
            let framesDir = scanDir.appendingPathComponent("frames")
            let meshesDir = scanDir.appendingPathComponent("meshes")
            let pointcloudDir = scanDir.appendingPathComponent("pointcloud")
            
            try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: meshesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: pointcloudDir, withIntermediateDirectories: true)
            
            // Store directory references
            currentScanId = scanId
            currentScanDirectory = scanDir
            framesDirectory = framesDir
            meshesDirectory = meshesDir
            pointcloudDirectory = pointcloudDir
            
            // Initialize metadata
            scanMetadata = ScanMetadata(scanId: scanId)
            saveMetadata()
            
            print("✅ Created scan directory structure at \(scanDir.path)")
        } catch {
            print("❌ Failed to create scan directory structure: \(error.localizedDescription)")
        }
    }
    
    /// Close the current scan and finalize metadata
    func closeCurrentScan() {
        guard currentScanId != nil, let metadata = scanMetadata else { return }
        
        var updatedMetadata = metadata
        updatedMetadata.lastUpdated = Date()
        updatedMetadata.status = "completed"
        updatedMetadata.processingProgress = 1.0
        scanMetadata = updatedMetadata
        
        saveMetadata()
        saveFramesMetadata()
        saveMeshAnchorsMetadata()
        
        print("✅ Closed scan: \(currentScanId ?? "unknown")")
        
        // Reset state
        currentScanId = nil
        currentScanDirectory = nil
        framesDirectory = nil
        meshesDirectory = nil
        pointcloudDirectory = nil
        scanMetadata = nil
        framesMetadata = []
        meshAnchorsMetadata = []
        frameCounter = 0
        meshAnchorCounter = 0
    }
    
    // MARK: - Saving Data
    
    /// Save a captured frame to disk
    func saveFrame(_ frame: CapturedFrame) {
        guard let framesDir = framesDirectory, let metadata = scanMetadata else {
            print("❌ Cannot save frame: No active scan")
            return
        }
        
        storageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Generate filename for the image
            let imageFilename = "frame_\(self.frameCounter).jpg"
            let imageURL = framesDir.appendingPathComponent(imageFilename)
            
            // Save the image as JPEG
            if let imageData = self.convertToJPEG(frame.image) {
                do {
                    try imageData.write(to: imageURL)
                    
                    // Create and save frame metadata
                    let frameMetadata = FrameMetadata(frame: frame, index: self.frameCounter, imageFilename: imageFilename)
                    self.framesMetadata.append(frameMetadata)
                    
                    // Update scan metadata
                    self.updateScanMetadata { metadata in
                        metadata.frameCount += 1
                        metadata.lastUpdated = Date()
                    }
                    
                    // Periodically save metadata (every 10 frames)
                    if self.frameCounter % 10 == 0 {
                        self.saveFramesMetadata()
                        self.saveMetadata()
                    }
                    
                    self.frameCounter += 1
                } catch {
                    print("❌ Failed to save frame image: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Save a mesh anchor to disk
    func saveMeshAnchor(_ anchor: ARMeshAnchor) {
        guard let meshesDir = meshesDirectory, let metadata = scanMetadata else {
            print("❌ Cannot save mesh anchor: No active scan")
            return
        }
        
        storageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Generate filename
            let filename = "mesh_\(self.meshAnchorCounter).bin"
            let fileURL = meshesDir.appendingPathComponent(filename)
            
            // Save mesh data
            if let (vertexCount, faceCount) = self.saveMeshGeometry(anchor.geometry, to: fileURL) {
                // Create and store metadata
                let anchorMetadata = MeshAnchorMetadata(
                    anchor: anchor,
                    timestamp: Date().timeIntervalSince1970,
                    filename: filename,
                    vertexCount: vertexCount,
                    faceCount: faceCount
                )
                self.meshAnchorsMetadata.append(anchorMetadata)
                
                // Update scan metadata
                self.updateScanMetadata { metadata in
                    metadata.meshAnchorCount += 1
                    metadata.lastUpdated = Date()
                }
                
                // Save metadata every 5 mesh anchors
                if self.meshAnchorCounter % 5 == 0 {
                    self.saveMeshAnchorsMetadata()
                    self.saveMetadata()
                }
                
                self.meshAnchorCounter += 1
            }
        }
    }
    
    /// Save point cloud data incrementally
    func savePartialPointCloud(vertices: [(position: SIMD3<Float>, color: SIMD3<UInt8>)]) {
        guard let pointcloudDir = pointcloudDirectory else {
            print("❌ Cannot save partial point cloud: No active scan")
            return
        }
        
        storageQueue.async {
            let timestamp = Int(Date().timeIntervalSince1970)
            let filename = "partial_cloud_\(timestamp).ply"
            let fileURL = pointcloudDir.appendingPathComponent(filename)
            
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
            for vertexData in vertices {
                plyBody += "\n\(vertexData.position.x) \(vertexData.position.y) \(vertexData.position.z) \(vertexData.color.x) \(vertexData.color.y) \(vertexData.color.z)"
            }
            
            let fullPlyContent = plyHeader + plyBody
            
            do {
                try fullPlyContent.write(to: fileURL, atomically: true, encoding: .utf8)
                print("✅ Saved partial point cloud with \(vertices.count) points")
            } catch {
                print("❌ Error writing partial point cloud: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Recovery Functions
    
    /// Check for existing scans that may need recovery
    func findRecoverableScans() -> [ScanMetadata] {
        var recoverableScans: [ScanMetadata] = []
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            
            for item in contents {
                if item.lastPathComponent.starts(with: "Scan_") {
                    let metadataURL = item.appendingPathComponent("metadata.json")
                    
                    if FileManager.default.fileExists(atPath: metadataURL.path) {
                        do {
                            let data = try Data(contentsOf: metadataURL)
                            let scanMetadata = try JSONDecoder().decode(ScanMetadata.self, from: data)
                            
                            if scanMetadata.status == "in-progress" {
                                recoverableScans.append(scanMetadata)
                            }
                        } catch {
                            print("Error reading metadata for potential recovery: \(error)")
                        }
                    }
                }
            }
        } catch {
            print("Error finding recoverable scans: \(error)")
        }
        
        return recoverableScans
    }
    
    /// Recover a previously interrupted scan
    func recoverScan(withId scanId: String) -> Bool {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scanDir = documentsDirectory.appendingPathComponent(scanId)
        
        guard FileManager.default.fileExists(atPath: scanDir.path) else {
            print("❌ Cannot recover scan: Directory doesn't exist")
            return false
        }
        
        do {
            // Load metadata
            let metadataURL = scanDir.appendingPathComponent("metadata.json")
            let data = try Data(contentsOf: metadataURL)
            let loadedMetadata = try JSONDecoder().decode(ScanMetadata.self, from: data)
            
            // Setup directories
            let framesDir = scanDir.appendingPathComponent("frames")
            let meshesDir = scanDir.appendingPathComponent("meshes")
            let pointcloudDir = scanDir.appendingPathComponent("pointcloud")
            
            // Store references
            currentScanId = scanId
            currentScanDirectory = scanDir
            framesDirectory = framesDir
            meshesDirectory = meshesDir
            pointcloudDirectory = pointcloudDir
            scanMetadata = loadedMetadata
            
            // Load frames metadata
            let framesMetadataURL = scanDir.appendingPathComponent(loadedMetadata.framesMetadataFile)
            if FileManager.default.fileExists(atPath: framesMetadataURL.path) {
                let framesData = try Data(contentsOf: framesMetadataURL)
                framesMetadata = try JSONDecoder().decode([FrameMetadata].self, from: framesData)
            }
            
            // Load mesh anchors metadata
            let meshAnchorsMetadataURL = scanDir.appendingPathComponent(loadedMetadata.meshAnchorsMetadataFile)
            if FileManager.default.fileExists(atPath: meshAnchorsMetadataURL.path) {
                let meshesData = try Data(contentsOf: meshAnchorsMetadataURL)
                meshAnchorsMetadata = try JSONDecoder().decode([MeshAnchorMetadata].self, from: meshesData)
            }
            
            // Set counters based on recovered data
            frameCounter = framesMetadata.count
            meshAnchorCounter = meshAnchorsMetadata.count
            
            print("✅ Successfully recovered scan: \(scanId)")
            return true
            
        } catch {
            print("❌ Failed to recover scan: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Helper Methods
    
    /// Save main scan metadata
    private func saveMetadata() {
        guard let metadata = scanMetadata, let scanDir = currentScanDirectory else { return }
        
        do {
            let metadataURL = scanDir.appendingPathComponent("metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL)
        } catch {
            print("❌ Failed to save scan metadata: \(error.localizedDescription)")
        }
    }
    
    /// Save frames metadata
    private func saveFramesMetadata() {
        guard let scanDir = currentScanDirectory, let metadata = scanMetadata else { return }
        
        do {
            let metadataURL = scanDir.appendingPathComponent(metadata.framesMetadataFile)
            let encoder = JSONEncoder()
            let data = try encoder.encode(framesMetadata)
            try data.write(to: metadataURL)
        } catch {
            print("❌ Failed to save frames metadata: \(error.localizedDescription)")
        }
    }
    
    /// Save mesh anchors metadata
    private func saveMeshAnchorsMetadata() {
        guard let scanDir = currentScanDirectory, let metadata = scanMetadata else { return }
        
        do {
            let metadataURL = scanDir.appendingPathComponent(metadata.meshAnchorsMetadataFile)
            let encoder = JSONEncoder()
            let data = try encoder.encode(meshAnchorsMetadata)
            try data.write(to: metadataURL)
        } catch {
            print("❌ Failed to save mesh anchors metadata: \(error.localizedDescription)")
        }
    }
    
    /// Update scan metadata with a closure
    private func updateScanMetadata(_ updates: (inout ScanMetadata) -> Void) {
        guard var metadata = scanMetadata else { return }
        updates(&metadata)
        scanMetadata = metadata
    }
    
    /// Convert CGImage to JPEG data
    private func convertToJPEG(_ image: CGImage, compressionQuality: CGFloat = 0.85) -> Data? {
        let uiImage = UIImage(cgImage: image)
        return uiImage.jpegData(compressionQuality: compressionQuality)
    }
    
    /// Save mesh geometry to a binary file
    private func saveMeshGeometry(_ geometry: ARMeshGeometry, to url: URL) -> (vertexCount: Int, faceCount: Int)? {
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
        var parsedFaces = [[UInt32]]()
        
        if faces.bytesPerIndex == 4 {
            for i in 0..<faces.count {
                var faceIndices = [UInt32]()
                for j in 0..<indicesPerFace {
                    let byteOffset = (i * indicesPerFace + j) * MemoryLayout<UInt32>.size
                    let indexPointer = facesBuffer.advanced(by: byteOffset)
                    faceIndices.append(indexPointer.assumingMemoryBound(to: UInt32.self).pointee)
                }
                parsedFaces.append(faceIndices)
            }
        } else if faces.bytesPerIndex == 2 {
            for i in 0..<faces.count {
                var faceIndices = [UInt32]()
                for j in 0..<indicesPerFace {
                    let byteOffset = (i * indicesPerFace + j) * MemoryLayout<UInt16>.size
                    let indexPointer = facesBuffer.advanced(by: byteOffset)
                    faceIndices.append(UInt32(indexPointer.assumingMemoryBound(to: UInt16.self).pointee))
                }
                parsedFaces.append(faceIndices)
            }
        } else {
            print("⚠️ Unsupported face index format")
            return nil
        }
        
        // Create a binary file with vertex and face data
        do {
            let fileHandle = try FileHandle(forWritingTo: url)
            
            // Write vertex count
            var vertexCount = UInt32(localVertices.count)
            let vertexCountData = Data(bytes: &vertexCount, count: MemoryLayout<UInt32>.size)
            fileHandle.write(vertexCountData)
            
            // Write vertices
            for vertex in localVertices {
                var v = vertex
                let vertexData = Data(bytes: &v, count: MemoryLayout<SIMD3<Float>>.size)
                fileHandle.write(vertexData)
            }
            
            // Write face count
            var faceCount = UInt32(parsedFaces.count)
            let faceCountData = Data(bytes: &faceCount, count: MemoryLayout<UInt32>.size)
            fileHandle.write(faceCountData)
            
            // Write face indices
            for face in parsedFaces {
                for index in face {
                    var idx = index
                    let indexData = Data(bytes: &idx, count: MemoryLayout<UInt32>.size)
                    fileHandle.write(indexData)
                }
            }
            
            try fileHandle.close()
            
            return (vertexCount: Int(vertexCount), faceCount: Int(faceCount))
        } catch {
            print("❌ Failed to save mesh geometry: \(error.localizedDescription)")
            return nil
        }
    }
}
