// PLYColorProcessor.swift
// PointCloudV3
// Created on 16/05/25
// Handles post-processing of PLY files with image data for improved color mapping

import Foundation
import ARKit
import UIKit
import simd

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
        var allPoints = [(position: SIMD3<Float>, confidence: Float)]()
        
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
                    transform.columns[i] = SIMD4<Float>(column[0], column[1], column[2], column[3])
                }
            }
            
            // Build intrinsics matrix
            var intrinsics = simd_float3x3()
            for (i, column) in intrinsicsArrays.enumerated() {
                if i < 3 && column.count >= 3 {
                    intrinsics.columns[i] = SIMD3<Float>(column[0], column[1], column[2])
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
    private static func loadPointsFromPLY(file: URL) -> [(position: SIMD3<Float>, confidence: Float)]? {
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
            var points = [(position: SIMD3<Float>, confidence: Float)]()
            
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
                    
                    points.append((position: SIMD3<Float>(x, y, z), confidence: confidence))
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
        _ points: [(position: SIMD3<Float>, confidence: Float)],
        using frames: [CameraFrameInfo]
    ) -> [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)] {
        var coloredPoints = [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)]()
        
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
                    if let (bestColor, bestConfidence) = findBestColorForPoint(point.position, in: frames) {
                        // Combine with original confidence
                        let finalConfidence = point.confidence * bestConfidence
                        coloredPoints.append((position: point.position, color: bestColor, confidence: finalConfidence))
                    } else {
                        // No color found, use default gray
                        coloredPoints.append((position: point.position, color: SIMD3<UInt8>(128, 128, 128), confidence: point.confidence))
                    }
                }
            }
            
            print("🔸 Processed batch \(batchIndex+1)/\(batches) - \(coloredPoints.count) points colored")
        }
        
        return coloredPoints
    }
    
    /// Find best color for a point from all camera frames
    private static func findBestColorForPoint(
        _ point: SIMD3<Float>,
        in frames: [CameraFrameInfo]
    ) -> (color: SIMD3<UInt8>, confidence: Float)? {
        var bestFrames = [(frame: CameraFrameInfo, score: Float, projectedPoint: SIMD2<Float>)]()
        
        // Find frames where this point is visible
        for frame in frames {
            guard let image = frame.image else { continue }
            
            // Project point to camera space
            let viewMatrix = frame.transform.inverse
            let viewPoint = viewMatrix * SIMD4<Float>(point.x, point.y, point.z, 1.0)
            
            // Check if point is behind camera
            if viewPoint.z >= 0 { continue }
            
            // Project to normalized image coordinates
            let fx = frame.intrinsics[0][0]
            let fy = frame.intrinsics[1][1]
            let cx = frame.intrinsics[2][0]
            let cy = frame.intrinsics[2][1]
            
            let x = -viewPoint.x / viewPoint.z * fx + cx
            let y = -viewPoint.y / viewPoint.z * fy + cy
            
            // Convert to pixel coordinates
            let imageWidth = Float(image.width)
            let imageHeight = Float(image.height)
            
            // Check bounds with margin
            let margin: Float = 5.0
            if x < margin || x >= imageWidth - margin || y < margin || y >= imageHeight - margin {
                continue
            }
            
            // Calculate view score (higher for points closer to center & camera)
            let centerX = imageWidth / 2
            let centerY = imageHeight / 2
            let distFromCenter = sqrt(pow(x - centerX, 2) + pow(y - centerY, 2)) / sqrt(pow(centerX, 2) + pow(centerY, 2))
            let distanceToCamera = abs(viewPoint.z)
            
            // Score is better when closer to center and closer to camera
            let viewScore = (1.0 - distFromCenter) * (1.0 / max(0.5, distanceToCamera))
            
            bestFrames.append((frame: frame, score: viewScore, projectedPoint: SIMD2<Float>(x, y)))
        }
        
        // If no frames found, return nil
        if bestFrames.isEmpty { return nil }
        
        // Sort by score (highest first)
        bestFrames.sort { $0.score > $1.score }
        
        // Use best frame or blend top frames
        if bestFrames.count == 1 {
            let frameData = bestFrames[0]
            let color = sampleColor(at: frameData.projectedPoint, from: frameData.frame.image!)
            return (color: color, confidence: frameData.score)
        } else {
            // Blend colors from top frames (up to 3)
            var totalWeight: Float = 0.0
            var weightedR: Float = 0.0
            var weightedG: Float = 0.0
            var weightedB: Float = 0.0
            
            for i in 0..<min(3, bestFrames.count) {
                let frameData = bestFrames[i]
                let weight = frameData.score / Float(i+1) // Reduce weight for less optimal frames
                
                let color = sampleColor(at: frameData.projectedPoint, from: frameData.frame.image!)
                weightedR += Float(color.x) * weight
                weightedG += Float(color.y) * weight
                weightedB += Float(color.z) * weight
                totalWeight += weight
            }
            
            // Normalize
            if totalWeight > 0 {
                weightedR /= totalWeight
                weightedG /= totalWeight
                weightedB /= totalWeight
                
                // Enhance color for better visibility
                let enhancedColor = enhanceColor(r: weightedR, g: weightedG, b: weightedB)
                
                return (
                    color: SIMD3<UInt8>(
                        UInt8(min(255, max(0, enhancedColor.r * 255.0))),
                        UInt8(min(255, max(0, enhancedColor.g * 255.0))),
                        UInt8(min(255, max(0, enhancedColor.b * 255.0)))
                    ),
                    confidence: bestFrames[0].score
                )
            }
        }
        
        return nil
    }
    
    /// Sample color from image at specified coordinates with bilinear interpolation
    private static func sampleColor(at point: SIMD2<Float>, from image: CGImage) -> SIMD3<UInt8> {
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
        points: [(position: SIMD3<Float>, color: SIMD3<UInt8>, confidence: Float)],
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

/// Camera frame information with image data
struct CameraFrameInfo {
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let timestamp: TimeInterval
    let imageResolution: CGSize
    let image: CGImage?
}
