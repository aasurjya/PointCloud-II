// EnhancedFrameCapture.swift
// PointCloudV3
// Created on 16/05/25
// Provides multi-resolution frame capture and advanced color mapping

import Foundation
import ARKit
import UIKit
import CoreImage
import simd

// MARK: - Enhanced Captured Frame

/// Enhanced frame with multiple resolutions and frame quality metadata
struct EnhancedCapturedFrame {
    // Original frame data
    let originalImage: CGImage
    let camera: ARCamera
    let timestamp: TimeInterval
    
    // Enhanced properties
    let highResImage: CGImage?  // Higher resolution for better color sampling
    let depthData: CVPixelBuffer? // Depth information if available
    let motionBlurScore: Float // 0.0 (blurry) to 1.0 (sharp)
    let captureQualityScore: Float // Overall quality score
    
    // For logging/debugging
    var debugName: String {
        return "Frame_\(Int(timestamp * 1000))"
    }
}

// MARK: - Enhanced Frame Capture

class EnhancedFrameCapture {
    // Use software rendering to avoid GPU memory issues
    private let ciContext = CIContext(options: [.useSoftwareRenderer: true])
    private var scanStorage: ScanStorage?
    
    // Configuration
    private let captureHighResolution: Bool
    private let captureDepth: Bool
    private let maxStoredFrames: Int
    
    // Initialization with configuration options
    init(captureHighRes: Bool = true, captureDepth: Bool = true, maxFrames: Int = 300) {
        self.captureHighResolution = captureHighRes
        self.captureDepth = captureDepth
        self.maxStoredFrames = maxFrames
    }
    
    // Set storage for continuous writing
    func setStorage(_ storage: ScanStorage) {
        self.scanStorage = storage
    }
    
    /// Process an ARFrame to create an enhanced captured frame
    func captureEnhancedFrame(from arFrame: ARFrame) -> EnhancedCapturedFrame? {
        let pixelBuffer = arFrame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Convert to RGB CGImage for consistent color processing
        guard let cgImage = ciContext.createCGImage(
            ciImage,
            from: ciImage.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            print("❌ Failed to convert camera image to RGB CGImage for \(arFrame.timestamp)")
            return nil
        }
        
        // Process high-res image if requested
        var highResImage: CGImage? = nil
        if captureHighResolution {
            // Upscale by 1.5x for better detail
            let scale: CGFloat = 1.5
            let width = Int(CGFloat(cgImage.width) * scale)
            let height = Int(CGFloat(cgImage.height) * scale)
            
            if let upscaledImage = upscaleImage(cgImage, toWidth: width, height: height) {
                highResImage = upscaledImage
            }
        }
        
        // Get depth data if available and requested
        var depthData: CVPixelBuffer? = nil
        if captureDepth {
            if #available(iOS 14.0, *) {
                // Try to get smoothed scene depth first
                if let smoothedSceneDepth = arFrame.smoothedSceneDepth?.depthMap {
                    depthData = smoothedSceneDepth
                } else if let sceneDepth = arFrame.sceneDepth?.depthMap {
                    depthData = sceneDepth
                }
            }
        }
        
        // Calculate simple motion blur score based on image sharpness
        let motionBlurScore = calculateMotionBlurScore(image: cgImage)
        
        // Lighting quality estimate derived from ARFrame's lightEstimate
        var lightingQuality: Float = 0.5
        if let lightEstimate = arFrame.lightEstimate {
            let ambientIntensity = lightEstimate.ambientIntensity
            // Optimal ambient intensity is around 1000
            let normalizedIntensity = min(1.0, Float(ambientIntensity) / 2000.0)
            lightingQuality = normalizedIntensity
        }
        
        // Compute overall quality score
        let captureQualityScore = motionBlurScore * 0.7 + lightingQuality * 0.3
        
        // Create enhanced frame
        let enhancedFrame = EnhancedCapturedFrame(
            originalImage: cgImage,
            camera: arFrame.camera,
            timestamp: arFrame.timestamp,
            highResImage: highResImage,
            depthData: depthData,
            motionBlurScore: motionBlurScore,
            captureQualityScore: captureQualityScore
        )
        
        // Save to storage if available
        if let storage = scanStorage {
            // Convert to the simple CapturedFrame format expected by storage
            let simpleFrame = CapturedFrame(
                image: highResImage ?? cgImage, // Use high-res if available
                camera: arFrame.camera,
                timestamp: arFrame.timestamp
            )
            storage.saveFrame(simpleFrame)
        }
        
        return enhancedFrame
    }
    
    // Calculate a simple motion blur score (higher is better/sharper)
    private func calculateMotionBlurScore(image: CGImage) -> Float {
        // Check image size and potentially downsample if too large
        let processImage = downsampleImageIfNeeded(image, maxDimension: 1024)
        
        // Use a simpler method to detect blur - laplacian variance
        return calculateLaplacianVariance(processImage)
    }
    
    // A more memory-efficient blur detection method
    private func calculateLaplacianVariance(_ image: CGImage) -> Float {
        // If image is too large, work with a downsampled version
        let imageToProcess = image.width > 1024 || image.height > 1024 ? 
                            downsampleImageIfNeeded(image, maxDimension: 1024) : image
        
        // Safe fallback if image is problematic
        guard let data = imageToProcess.dataProvider?.data, 
              CFDataGetLength(data) > 0 else {
            return 0.5 // Default medium value
        }
        
        // Create a direct bitmap access to avoid CIContext rendering issues
        let bytesPerRow = imageToProcess.bytesPerRow
        let bytesPerPixel = imageToProcess.bitsPerPixel / 8
        let pixelData = CFDataGetBytePtr(data)
        
        // For performance, just sample a portion of the image
        let sampleStride = max(1, imageToProcess.width / 100) // Sample every Nth pixel
        var sumOfSquares: Float = 0
        var count: Int = 0
        
        // Calculate variation in pixel values as a proxy for image sharpness
        for y in stride(from: 2, to: imageToProcess.height-2, by: sampleStride) {
            for x in stride(from: 2, to: imageToProcess.width-2, by: sampleStride) {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                
                // Basic grayscale conversion and neighbor comparison
                if let pixel = pixelData?[pixelIndex], 
                   let pixelUp = pixelData?[pixelIndex - bytesPerRow],
                   let pixelDown = pixelData?[pixelIndex + bytesPerRow] {
                    // Calculate simple derivative
                    let diff = abs(Float(pixel) - Float(pixelUp)) + abs(Float(pixel) - Float(pixelDown))
                    sumOfSquares += diff * diff
                    count += 1
                }
            }
        }
        
        // Calculate variance (higher value = sharper image)
        let variance = count > 0 ? sqrt(sumOfSquares / Float(count)) / 255.0 : 0.5
        
        // Normalize to 0-1 range with proper scaling
        let normalizedScore = min(1.0, max(0.0, variance * 4.0))
        
        return normalizedScore
    }
    
    // Helper: Downsample an image to reduce memory usage
    private func downsampleImageIfNeeded(_ image: CGImage, maxDimension: Int) -> CGImage {
        // If image is already small enough, return as-is
        if image.width <= maxDimension && image.height <= maxDimension {
            return image
        }
        
        // Calculate new size maintaining aspect ratio
        let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
        let targetWidth, targetHeight: Int
        
        if aspectRatio > 1 {
            targetWidth = maxDimension
            targetHeight = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            targetHeight = maxDimension
            targetWidth = Int(CGFloat(maxDimension) * aspectRatio)
        }
        
        // Create a smaller context for drawing the downsampled image
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image // Return original if downsample fails
        }
        
        // Use low quality interpolation for speed
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        return context.makeImage() ?? image
    }
    
    // Upscale an image using high-quality interpolation
    private func upscaleImage(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return nil
        }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
