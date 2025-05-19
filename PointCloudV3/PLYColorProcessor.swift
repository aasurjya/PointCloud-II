// PLYColorProcessor.swift
// PointCloudV3
// Created on 16/05/25
// Handles post-processing of PLY files with image data for improved color mapping

import Foundation
import ARKit
import UIKit
import simd
import SceneKit
import ModelIO
import SceneKit.ModelIO

class PLYColorProcessor {
    /// Process a directory containing PLY and image files to create a colored point cloud
    /// - Parameters:
    ///   - inputDirectory: Directory containing PLY files and frame images
    ///   - outputFilename: Name for the output colored PLY file
    /// - Returns: Success flag and path to output file
    static func processDirectoryToColoredPLY(
        inputDirectory: URL,
        outputFilename: String = "colored_pointcloud.ply"
    ) -> (success: Bool, outputPath: URL?) {
        print("🔍 Starting PLY color processing for directory: \(inputDirectory.lastPathComponent)")
        
        // Output file path
        let outputPath = inputDirectory.appendingPathComponent(outputFilename)
        
        // Find all PLY files
        let fileManager = FileManager.default
        guard let directoryContents = try? fileManager.contentsOfDirectory(
            at: inputDirectory,
            includingPropertiesForKeys: nil
        ) else {
            print("❌ Could not access directory contents")
            return (false, nil)
        }
        
        // Find PLY files
        let plyFiles = directoryContents.filter { $0.pathExtension.lowercased() == "ply" }
        guard !plyFiles.isEmpty else {
            print("❌ No PLY files found in directory")
            return (false, nil)
        }
        print("🔹 Found \(plyFiles.count) PLY files")
        
        // Find image files for color mapping
        let imageFiles = directoryContents.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "jpg" || ext == "jpeg" || ext == "png"
        }
        guard !imageFiles.isEmpty else {
            print("❌ No image files found for color mapping")
            return (false, nil)
        }
        print("🔹 Found \(imageFiles.count) image files for color mapping")
        
        // Find camera info files (JSON)
        let jsonFiles = directoryContents.filter { $0.pathExtension.lowercased() == "json" }
        guard !jsonFiles.isEmpty else {
            print("❌ No camera JSON files found")
            return (false, nil)
        }
        print("🔹 Found \(jsonFiles.count) JSON camera files")
        
        // Build camera transforms from JSON files
        var cameraFrames = [CameraFrameInfo]()
        for jsonFile in jsonFiles {
            if let frameInfo = loadCameraInfo(from: jsonFile) {
                // Find matching image file
                let baseName = jsonFile.deletingPathExtension().lastPathComponent
                let imageBaseName = baseName.replacingOccurrences(of: "camera_", with: "frame_")
                
                if let matchingImage = imageFiles.first(where: {
                    $0.deletingPathExtension().lastPathComponent == imageBaseName
                }) {
                    if let image = UIImage(contentsOfFile: matchingImage.path),
                       let cgImage = image.cgImage {
                        let frameWithImage = CameraFrameInfo(
                            transform: frameInfo.transform,
                            intrinsics: frameInfo.intrinsics,
                            timestamp: frameInfo.timestamp,
                            imageResolution: frameInfo.imageResolution,
                            image: cgImage
                        )
                        cameraFrames.append(frameWithImage)
                    }
                }
            }
        }
        
        guard !cameraFrames.isEmpty else {
            print("❌ Failed to load camera frames with images")
            return (false, nil)
        }
        print("✅ Loaded \(cameraFrames.count) camera frames with images")
        
        // Process each PLY file to extract points
        var allPoints = [(position: simd_float3, confidence: Float)]()
        
        for plyFile in plyFiles {
            if let points = loadPointsFromPLY(file: plyFile) {
                allPoints.append(contentsOf: points)
                print("🔹 Loaded \(points.count) points from \(plyFile.lastPathComponent)")
            }
        }
        
        guard !allPoints.isEmpty else {
            print("❌ No points loaded from PLY files")
            return (false, nil)
        }
        print("✅ Loaded \(allPoints.count) total points from all PLY files")
        
        // Apply colors to points
        let coloredPoints = applyColorsToPoints(allPoints, using: cameraFrames)
        
        // Save colored points to PLY
        let success = saveToPLY(points: coloredPoints, to: outputPath)
        
        if success {
            print("✅ Successfully saved colored point cloud to: \(outputPath.path)")
            return (true, outputPath)
        } else {
            print("❌ Failed to save colored point cloud")
            return (false, nil)
        }
    }
    
    /// Load camera information from a JSON file
    private static func loadCameraInfo(from jsonFile: URL) -> CameraFrameInfo? {
        do {
            let data = try Data(contentsOf: jsonFile)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            guard let json = json,
                  let timestamp = json["timestamp"] as? TimeInterval,
                  let transformArrays = json["transform"] as? [[Float]],
                  let intrinsicsArrays = json["intrinsics"] as? [[Float]],
                  let resolutionArray = json["imageResolution"] as? [CGFloat] else {
                return nil
            }
            
            // Build transform matrix
            var transform = simd_float4x4()
            for (i, column) in transformArrays.enumerated() {
                if i < 4 && column.count >= 4 {
                    if i == 0 {
                        transform.columns.0 = simd_float4(column[0], column[1], column[2], column[3])
                    } else if i == 1 {
                        transform.columns.1 = simd_float4(column[0], column[1], column[2], column[3])
                    } else if i == 2 {
                        transform.columns.2 = simd_float4(column[0], column[1], column[2], column[3])
                    } else if i == 3 {
                        transform.columns.3 = simd_float4(column[0], column[1], column[2], column[3])
                    }
                }
            }
            
            // Build intrinsics matrix
            var intrinsics = simd_float3x3()
            for (i, column) in intrinsicsArrays.enumerated() {
                if i < 3 && column.count >= 3 {
                    if i == 0 {
                        intrinsics.columns.0 = simd_float3(column[0], column[1], column[2])
                    } else if i == 1 {
                        intrinsics.columns.1 = simd_float3(column[0], column[1], column[2])
                    } else if i == 2 {
                        intrinsics.columns.2 = simd_float3(column[0], column[1], column[2])
                    }
                }
            }
            
            // Image resolution
            let imageResolution = CGSize(
                width: resolutionArray.count > 0 ? resolutionArray[0] : 1920,
                height: resolutionArray.count > 1 ? resolutionArray[1] : 1440
            )
            
            return CameraFrameInfo(
                transform: transform,
                intrinsics: intrinsics,
                timestamp: timestamp,
                imageResolution: imageResolution,
                image: nil
            )
        } catch {
            print("❌ Error loading camera info from \(jsonFile.lastPathComponent): \(error)")
            return nil
        }
    }
    
    /// Load points from a PLY file
    private static func loadPointsFromPLY(file: URL) -> [(position: simd_float3, confidence: Float)]? {
        do {
            let content = try String(contentsOf: file, encoding: .utf8)
            var lines = content.split(separator: "\n")
            
            // Skip header
            var i = 0
            var headerEndIndex = 0
            while i < lines.count {
                if lines[i].contains("end_header") {
                    headerEndIndex = i + 1
                    break
                }
                i += 1
            }
            
            if headerEndIndex >= lines.count {
                print("❌ Invalid PLY file format in \(file.lastPathComponent)")
                return nil
            }
            
            // Parse points
            var points = [(position: simd_float3, confidence: Float)]()
            
            for i in headerEndIndex..<lines.count {
                let line = lines[i]
                let components = line.split(separator: " ")
                
                // Check for valid point data (at least x,y,z)
                if components.count >= 3,
                   let x = Float(components[0]),
                   let y = Float(components[1]),
                   let z = Float(components[2]) {
                    
                    // Get confidence if available (usually 7th value)
                    let confidence: Float
                    if components.count >= 7, let conf = Float(components[6]) {
                        confidence = conf
                    } else {
                        confidence = 1.0 // Default confidence
                    }
                    
                    points.append((position: simd_float3(x, y, z), confidence: confidence))
                }
            }
            
            return points
            
        } catch {
            print("❌ Error loading points from PLY \(file.lastPathComponent): \(error)")
            return nil
        }
    }
    
    /// Apply colors to points using camera frames
    private static func applyColorsToPoints(
        _ points: [(position: simd_float3, confidence: Float)],
        using frames: [CameraFrameInfo]
    ) -> [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)] {
        var coloredPoints = [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)]()
        
        // Process in batches to avoid memory pressure
        let batchSize = 10000
        let batches = (points.count + batchSize - 1) / batchSize
        
        for batchIndex in 0..<batches {
            let startIndex = batchIndex * batchSize
            let endIndex = min(startIndex + batchSize, points.count)
            
            autoreleasepool {
                for i in startIndex..<endIndex {
                    let point = points[i]
                    
                    // Find best frame for this point
                    let colorInfo = findBestColorForPoint(point.position, in: frames)
                    
                    // Combine with original confidence
                    let finalConfidence = point.confidence * colorInfo.confidence
                    coloredPoints.append((position: point.position, color: colorInfo.color, confidence: finalConfidence))
                }
            }
            
            print("🔸 Processed batch \(batchIndex+1)/\(batches) - \(coloredPoints.count) points colored")
        }
        
        return coloredPoints
    }
    
    /// Find best color for a point from all camera frames
    private static func findBestColorForPoint(
        _ point: simd_float3,
        in frames: [CameraFrameInfo]
    ) -> (color: SIMD3<UInt8>, confidence: Float) {
        var bestFrames = [(frame: CameraFrameInfo, score: Float, projectedPoint: simd_float2)]()
        
        // Track closest possible frame even if point is out of view
        var fallbackFrames = [(frame: CameraFrameInfo, distance: Float)]()
        
        // Find frames where this point is visible
        for frame in frames {
            guard let image = frame.image else { continue }
            
            // Calculate distance to camera - save as fallback regardless of visibility
            let cameraPos = simd_float3(
                frame.transform.columns.3.x,
                frame.transform.columns.3.y,
                frame.transform.columns.3.z
            )
            let distToCamera = length(point - cameraPos)
            fallbackFrames.append((frame: frame, distance: distToCamera))
            
            // Project point to camera space
            let viewMatrix = frame.transform.inverse
            let viewPoint = viewMatrix * simd_float4(point.x, point.y, point.z, 1.0)
            
            // More relaxed depth check - only exclude extreme cases
            if viewPoint.z >= -0.1 { continue }
            
            // Project to normalized image coordinates
            let fx = frame.intrinsics.columns.0.x
            let fy = frame.intrinsics.columns.1.y
            let cx = frame.intrinsics.columns.2.x
            let cy = frame.intrinsics.columns.2.y
            
            let x = -viewPoint.x / viewPoint.z * fx + cx
            let y = -viewPoint.y / viewPoint.z * fy + cy
            
            // Convert to pixel coordinates
            let imageWidth = Float(image.width)
            let imageHeight = Float(image.height)
            
            // Much more relaxed bounds checking - use padding instead of skipping
            let paddedX = max(2.0, min(imageWidth - 2.0, x))
            let paddedY = max(2.0, min(imageHeight - 2.0, y))
            
            // Use relaxed visibility scoring
            var visibilityScore: Float = 1.0
            
            // Reduce score but don't eliminate points outside image center
            if x < 0 || x >= imageWidth || y < 0 || y >= imageHeight {
                visibilityScore = 0.5  // Penalty for being outside image bounds, but still usable
            } else {
                // Calculate view score (higher for points closer to center & camera)
                let centerX = imageWidth / 2
                let centerY = imageHeight / 2
                let distFromCenter = sqrt(pow(x - centerX, 2) + pow(y - centerY, 2)) / sqrt(pow(centerX, 2) + pow(centerY, 2))
                visibilityScore = (1.0 - distFromCenter * 0.7) // Less penalty for being off-center
            }
            
            // Depth scoring - closer to camera is better
            let depthScore = 1.0 / max(0.3, abs(viewPoint.z))
            
            // Final score combines visibility and depth
            let viewScore = visibilityScore * depthScore
            
            bestFrames.append((frame: frame, score: viewScore, projectedPoint: simd_float2(paddedX, paddedY)))
        }
        
        // If we found at least one usable frame
        if !bestFrames.isEmpty {
            // Sort by score (highest first)
            bestFrames.sort { $0.score > $1.score }
            
            // Choose the best frame to sample from
            let frameData = bestFrames[0]
            let mainColor = sampleColor(at: frameData.projectedPoint, from: frameData.frame.image!)
            
            // If we have more than 1 frame, blend with the second best
            if bestFrames.count > 1 {
                let secondFrameData = bestFrames[1]
                let secondColor = sampleColor(at: secondFrameData.projectedPoint, from: secondFrameData.frame.image!)
                
                // Blend weights based on score ratio
                let totalScore = frameData.score + secondFrameData.score
                let weight1 = frameData.score / totalScore
                let weight2 = secondFrameData.score / totalScore
                
                // Blend colors
                let blendedR = Float(mainColor.x) * weight1 + Float(secondColor.x) * weight2
                let blendedG = Float(mainColor.y) * weight1 + Float(secondColor.y) * weight2
                let blendedB = Float(mainColor.z) * weight1 + Float(secondColor.z) * weight2
                
                // Enhance color
                let enhancedColor = enhanceColor(r: blendedR, g: blendedG, b: blendedB)
                return (
                    color: SIMD3<UInt8>(
                        UInt8(min(255, max(0, enhancedColor.r))),
                        UInt8(min(255, max(0, enhancedColor.g))),
                        UInt8(min(255, max(0, enhancedColor.b)))
                    ),
                    confidence: frameData.score
                )
            }
            
            // Enhance color for single frame
            let enhancedColor = enhanceColor(r: Float(mainColor.x), g: Float(mainColor.y), b: Float(mainColor.z))
            return (
                color: SIMD3<UInt8>(
                    UInt8(min(255, max(0, enhancedColor.r))),
                    UInt8(min(255, max(0, enhancedColor.g))),
                    UInt8(min(255, max(0, enhancedColor.b)))
                ),
                confidence: frameData.score
            )
        }
        
        // FALLBACK: If no good view was found, use nearest camera frame
        if !fallbackFrames.isEmpty {
            // Sort by distance to camera (closest first)
            fallbackFrames.sort { $0.distance < $1.distance }
            
            // Use closest camera for color estimation
            let closestFrame = fallbackFrames[0]
            
            // Create a synthetic projection - project to center of image
            let image = closestFrame.frame.image!
            let centerPoint = simd_float2(Float(image.width/2), Float(image.height/2))
            
            // Sample color from image center and adjust based on distance
            let baseColor = sampleColor(at: centerPoint, from: image)
            
            // Calculate a distance-based weight (farther = more gray)
            let distanceWeight = min(1.0, 5.0 / max(1.0, closestFrame.distance))
            
            // Blend with gray based on distance
            let gray: UInt8 = 180
            let r = UInt8(Float(baseColor.x) * distanceWeight + Float(gray) * (1.0 - distanceWeight))
            let g = UInt8(Float(baseColor.y) * distanceWeight + Float(gray) * (1.0 - distanceWeight))
            let b = UInt8(Float(baseColor.z) * distanceWeight + Float(gray) * (1.0 - distanceWeight))
            
            return (color: SIMD3<UInt8>(r, g, b), confidence: 0.5)
        }
        
        // Last resort - return a default color if nothing else worked
        return (color: SIMD3<UInt8>(200, 200, 200), confidence: 0.1)
    }
    
    /// Sample color from image at specified coordinates with bilinear interpolation
    private static func sampleColor(at point: simd_float2, from image: CGImage) -> SIMD3<UInt8> {
        let x = Float(point.x)
        let y = Float(point.y)
        
        // Bounds check
        guard x >= 0, y >= 0, x < Float(image.width), y < Float(image.height) else {
            return SIMD3<UInt8>(128, 128, 128) // Default gray
        }
        
        // Get image data
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else {
            return SIMD3<UInt8>(128, 128, 128)
        }
        
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        
        // Bilinear interpolation
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(x0 + 1, image.width - 1)
        let y1 = min(y0 + 1, image.height - 1)
        
        let u = x - Float(x0)
        let v = y - Float(y0)
        let oneMinusU = 1.0 - u
        let oneMinusV = 1.0 - v
        
        // Sampling helper function
        func getColorAt(x: Int, y: Int, offset: Int) -> UInt8 {
            let index = y * bytesPerRow + x * bytesPerPixel + offset
            if index >= 0 && index < CFDataGetLength(data) {
                return ptr[index]
            }
            return 128
        }
        
        // Handle different byte orders
        let (rOffset, gOffset, bOffset): (Int, Int, Int)
        if image.bitmapInfo.contains(.byteOrder32Little) {
            // BGR format
            (rOffset, gOffset, bOffset) = (2, 1, 0)
        } else {
            // RGB format
            (rOffset, gOffset, bOffset) = (0, 1, 2)
        }
        
        // Sample color components
        let r00 = Float(getColorAt(x: x0, y: y0, offset: rOffset))
        let r01 = Float(getColorAt(x: x0, y: y1, offset: rOffset))
        let r10 = Float(getColorAt(x: x1, y: y0, offset: rOffset))
        let r11 = Float(getColorAt(x: x1, y: y1, offset: rOffset))
        
        let g00 = Float(getColorAt(x: x0, y: y0, offset: gOffset))
        let g01 = Float(getColorAt(x: x0, y: y1, offset: gOffset))
        let g10 = Float(getColorAt(x: x1, y: y0, offset: gOffset))
        let g11 = Float(getColorAt(x: x1, y: y1, offset: gOffset))
        
        let b00 = Float(getColorAt(x: x0, y: y0, offset: bOffset))
        let b01 = Float(getColorAt(x: x0, y: y1, offset: bOffset))
        let b10 = Float(getColorAt(x: x1, y: y0, offset: bOffset))
        let b11 = Float(getColorAt(x: x1, y: y1, offset: bOffset))
        
        // Interpolate
        let r = oneMinusU * oneMinusV * r00 + u * oneMinusV * r10 + oneMinusU * v * r01 + u * v * r11
        let g = oneMinusU * oneMinusV * g00 + u * oneMinusV * g10 + oneMinusU * v * g01 + u * v * g11
        let b = oneMinusU * oneMinusV * b00 + u * oneMinusV * b10 + oneMinusU * v * b01 + u * v * b11
        
        return SIMD3<UInt8>(
            UInt8(min(255, max(0, r))),
            UInt8(min(255, max(0, g))),
            UInt8(min(255, max(0, b)))
        )
    }
    
    /// Enhance color to make it more vibrant
    private static func enhanceColor(r: Float, g: Float, b: Float) -> (r: Float, g: Float, b: Float) {
        // Convert to HSV for better enhancement
        let (h, s, v) = rgbToHsv(r: r/255.0, g: g/255.0, b: b/255.0)
        
        // For very light colors, apply stronger saturation
        let isVeryLight = v > 0.9 && s < 0.2
        let isNearWhite = v > 0.8 && s < 0.3
        
        let enhancedS: Float
        if isVeryLight {
            enhancedS = min(1.0, s * 8.0) // Stronger saturation for very light colors
        } else if isNearWhite {
            enhancedS = min(1.0, s * 4.0) // Stronger saturation for near-white
        } else {
            enhancedS = min(1.0, s * 1.5) // Normal saturation boost
        }
        
        // Convert back to RGB
        let (finalR, finalG, finalB) = hsvToRgb(h: h, s: enhancedS, v: v)
        return (r: finalR * 255.0, g: finalG * 255.0, b: finalB * 255.0)
    }
    
    /// Convert RGB to HSV
    private static func rgbToHsv(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let cmax = max(max(r, g), b)
        let cmin = min(min(r, g), b)
        let delta = cmax - cmin
        
        // Calculate hue
        var h: Float = 0.0
        if delta != 0 {
            if cmax == r {
                h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if cmax == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        
        // Calculate saturation and value
        let s = cmax == 0 ? 0 : delta / cmax
        let v = cmax
        
        return (h / 360.0, s, v)
    }
    
    /// Convert HSV to RGB
    private static func hsvToRgb(h: Float, s: Float, v: Float) -> (r: Float, g: Float, b: Float) {
        let h = h * 360.0 // Scale to 0-360
        let c = v * s
        let x = c * (1 - abs((h / 60.0).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        
        var r: Float = 0.0
        var g: Float = 0.0
        var b: Float = 0.0
        
        if h < 60 {
            r = c; g = x; b = 0
        } else if h < 120 {
            r = x; g = c; b = 0
        } else if h < 180 {
            r = 0; g = c; b = x
        } else if h < 240 {
            r = 0; g = x; b = c
        } else if h < 300 {
            r = x; g = 0; b = c
        } else {
            r = c; g = 0; b = x
        }
        
        return (r + m, g + m, b + m)
    }
    
    /// Save colored points to PLY file
    private static func saveToPLY(
            points: [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)],
            to url: URL
        ) -> Bool {
            do {
                // Create header
                var plyContent = """
            ply
            format ascii 1.0
            comment Generated by PointCloudV3 Color Processor
            element vertex \(points.count)
            property float x
            property float y
            property float z
            property uchar red
            property uchar green
            property uchar blue
            end_header
            
            """
                
                // Write points in batches to avoid memory issues
                let batchSize = 10000
                let batches = (points.count + batchSize - 1) / batchSize
                
                for batchIndex in 0..<batches {
                    let startIndex = batchIndex * batchSize
                    let endIndex = min(startIndex + batchSize, points.count)
                    
                    var batchContent = ""
                    
                    for i in startIndex..<endIndex {
                        let point = points[i]
                        batchContent += "\(point.position.x) \(point.position.y) \(point.position.z) "
                        batchContent += "\(point.color.x) \(point.color.y) \(point.color.z)\n"
                    }
                    
                    plyContent += batchContent
                    
                    // Clear batch content to free memory
                    batchContent = ""
                    
                    // Write to file periodically
                    if batchIndex % 5 == 0 || batchIndex == batches - 1 {
                        if batchIndex == 0 {
                            try plyContent.write(to: url, atomically: true, encoding: .utf8)
                        } else {
                            // Append to existing file
                            if let fileHandle = try? FileHandle(forWritingTo: url) {
                                try fileHandle.seekToEnd()
                                if let data = batchContent.data(using: .utf8) {
                                    try fileHandle.write(contentsOf: data)
                                }
                                try fileHandle.close()
                            }
                        }
                    }
                }
                
                return true
                
            } catch {
                print("❌ Error saving PLY file: \(error)")
                return false
            }
        }
    }
    
    /// Load a PLY file and return the colored point cloud data
    /// - Parameter fromURL: URL to the PLY file
    /// - Returns: Array of points with position, color, and confidence values
    func loadPLYFile(fromURL url: URL) -> [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)]? {
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
    func generateMesh(
        from pointCloud: [(position: simd_float3, color: SIMD3<UInt8>, confidence: Float)],
        outputPath: URL
    ) -> (success: Bool, outputPath: URL?) {
        print("Generating mesh from \(pointCloud.count) points")
        
        // Create SCNGeometry sources
        var vertices = [SCNVector3]()
        var colors = [SCNVector3]()
        
        // Convert point cloud to SCNGeometry format
        for point in pointCloud {
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
    
    /// Camera frame information with image data
    struct CameraFrameInfo {
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
        let timestamp: TimeInterval
        let imageResolution: CGSize
        let image: CGImage?
    }
    
    func distance(_ a: simd_float3, _ b: simd_float3) -> Float {
        return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2))
    }
