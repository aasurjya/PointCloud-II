import RealityKit
import Combine
import SwiftUI
import UIKit
import CoreImage

@available(iOS 17.0, *)
class PhotogrammetryService: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var generatedModelURL: URL?
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false
    @Published var processingStage: String = ""
    
    private var session: PhotogrammetrySession?
    private var currentOutputURL: URL?
    private var sessionTask: Task<Void, Never>?
    // Enhanced configuration options
    struct ProcessingOptions {
        let detailLevel: PhotogrammetrySession.Request.Detail
        let featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity
        let sampleOrdering: PhotogrammetrySession.Configuration.SampleOrdering
        let enableObjectMasking: Bool
        let maxImageCount: Int?
        
        static let highQuality = ProcessingOptions(
            detailLevel: .reduced,  // Changed from .maximum
            featureSensitivity: .high,
            sampleOrdering: .sequential,
            enableObjectMasking: false,
            maxImageCount: nil
        )
        
        static let balanced = ProcessingOptions(
            detailLevel: .reduced,  // Already correct
            featureSensitivity: .normal,
            sampleOrdering: .unordered,
            enableObjectMasking: false,
            maxImageCount: 200
        )
        
        static let fast = ProcessingOptions(
            detailLevel: .reduced,  // Changed from .preview
            featureSensitivity: .normal,
            sampleOrdering: .unordered,
            enableObjectMasking: false,
            maxImageCount: 100
        )
    }



    init() {}
    
    func generateUSDZ(from imageDirectoryURL: URL,
                     outputFileName: String,
                     options: ProcessingOptions = .balanced) {
        
        print("📸 Starting USDZ generation with \(options.detailLevel) detail")
        
        // Enhanced image validation
        guard let validatedImages = validateAndPrepareImages(at: imageDirectoryURL,
                                                           maxCount: options.maxImageCount) else {
            return
        }
        
        // Create optimized configuration
        let configuration = createOptimizedConfiguration(for: options, imageCount: validatedImages.count)
        
        // Continue with session creation
        createPhotogrammetrySession(with: configuration,
                                   imageDirectory: imageDirectoryURL,
                                   outputFileName: outputFileName,
                                   options: options)
    }
    
    private func validateAndPrepareImages(at directory: URL, maxCount: Int?) -> [URL]? {
        do {
            let fileManager = FileManager.default
            let supportedExtensions = ["jpg", "jpeg", "png", "heic", "tiff"]
            
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            // Filter and sort images
            var imageFiles = contents.filter { url in
                supportedExtensions.contains(url.pathExtension.lowercased())
            }.sorted { url1, url2 in
                // Sort by creation date if available, otherwise by name
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 < date2
            }
            
            print("📊 Found \(imageFiles.count) potential images")
            
            // Validate image quality and characteristics
            var validImages: [URL] = []
            var validationResults: [String] = []
            
            for (index, imageURL) in imageFiles.enumerated() {
                if let validationResult = validateImage(at: imageURL, index: index) {
                    validImages.append(imageURL)
                    validationResults.append("✅ \(imageURL.lastPathComponent): \(validationResult)")
                } else {
                    validationResults.append("❌ \(imageURL.lastPathComponent): Failed validation")
                }
                
                // Apply max count limit if specified
                if let maxCount = maxCount, validImages.count >= maxCount {
                    print("📊 Reached maximum image count (\(maxCount))")
                    break
                }
            }
            
            // Print validation summary
            print("📋 Image Validation Results:")
            validationResults.prefix(10).forEach { print("  \($0)") }
            if validationResults.count > 10 {
                print("  ... and \(validationResults.count - 10) more")
            }
            
            // Check minimum requirements
            let minImages = 10
            guard validImages.count >= minImages else {
                DispatchQueue.main.async {
                    self.errorMessage = "Need at least \(minImages) valid images. Found \(validImages.count)."
                    self.isProcessing = false
                }
                return nil
            }
            
            print("✅ Validated \(validImages.count) images for processing")
            return validImages
            
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Error accessing image directory: \(error.localizedDescription)"
                self.isProcessing = false
            }
            return nil
        }
    }
    
    private func validateImage(at url: URL, index: Int) -> String? {
        // Check file size
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 50_000 else { // At least 50KB
            return nil
        }
        
        // Load and validate image
        guard let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        
        let size = image.size
        let minDimension: CGFloat = 1024 // Higher minimum for better quality
        let maxDimension: CGFloat = 8192 // Reasonable upper limit
        
        guard size.width >= minDimension && size.height >= minDimension else {
            return nil
        }
        
        guard size.width <= maxDimension && size.height <= maxDimension else {
            return nil
        }
        
        // Check aspect ratio (avoid extremely wide/tall images)
        let aspectRatio = max(size.width, size.height) / min(size.width, size.height)
        guard aspectRatio <= 3.0 else {
            return nil
        }
        
        // Check for potential blur (basic check)
        if let cgImage = image.cgImage {
            let context = CIContext()
            let ciImage = CIImage(cgImage: cgImage)
            
            // Simple sharpness check using variance of Laplacian
            if let sharpnessValue = calculateImageSharpness(ciImage: ciImage, context: context) {
                guard sharpnessValue > 100 else { // Threshold for acceptable sharpness
                    return nil
                }
                return "\(Int(size.width))x\(Int(size.height)), \(fileSize/1024)KB, sharpness: \(Int(sharpnessValue))"
            }
        }
        
        return "\(Int(size.width))x\(Int(size.height)), \(fileSize/1024)KB"
    }
    
    private func calculateImageSharpness(ciImage: CIImage, context: CIContext) -> Double? {
        // Apply Laplacian filter to detect edges (sharpness indicator)
        guard let filter = CIFilter(name: "CIConvolution3X3") else { return nil }
        
        let laplacianKernelFloat: [Float] = [
            0, -1, 0,
            -1, 4, -1,
            0, -1, 0
        ]

        // Convert Float array to CGFloat array
        let laplacianKernel = laplacianKernelFloat.map { CGFloat($0) }

        filter.setValue(ciImage, forKey: kCIInputImageKey)

        // Use withUnsafeBufferPointer for safe array access
        laplacianKernel.withUnsafeBufferPointer { bufferPointer in
            if let baseAddress = bufferPointer.baseAddress {
                let ciVector = CIVector(values: baseAddress, count: Int(UInt(laplacianKernel.count)))
                filter.setValue(ciVector, forKey: "inputWeights")
            }
        }

 guard let outputImage = filter.outputImage else { return nil }
        
        // Calculate variance (higher variance = sharper image)
        let extent = outputImage.extent
        let inputExtent = CGRect(x: 0, y: 0, width: min(extent.width, 500), height: min(extent.height, 500))
        
        guard let cgImage = context.createCGImage(outputImage, from: inputExtent) else { return nil }
        
        // Simple variance calculation on a subset of pixels
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data else { return nil }
        
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let width = cgImage.width
        let height = cgImage.height
        
        // Convert to UInt8 pointer instead of mixing Float/CGFloat
        let ptr = CFDataGetBytePtr(data)
        guard let bytePtr = ptr else { return nil }
        
        var sum: Double = 0
        var sumSquared: Double = 0
        var count: Int = 0
        
        for y in stride(from: 0, to: height, by: 10) {
            for x in stride(from: 0, to: width, by: 10) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if offset < CFDataGetLength(data) {
                    let value = Double(bytePtr[offset])  // Direct byte access
                    sum += value
                    sumSquared += value * value
                    count += 1
                }
            }
        }
        
        guard count > 0 else { return nil }
        
        let mean = sum / Double(count)
        let variance = (sumSquared / Double(count)) - (mean * mean)
        
        return variance
    }

    
    private func createOptimizedConfiguration(for options: ProcessingOptions, imageCount: Int) -> PhotogrammetrySession.Configuration {
        var configuration = PhotogrammetrySession.Configuration()
        
        // Set sample ordering based on image count and naming
        configuration.sampleOrdering = options.sampleOrdering
        
        // Adjust feature sensitivity based on image quality
        configuration.featureSensitivity = options.featureSensitivity
        
        // Enable object masking if requested
        configuration.isObjectMaskingEnabled = options.enableObjectMasking
        
        print("📋 Configuration:")
        print("  - Sample Ordering: \(configuration.sampleOrdering)")
        print("  - Feature Sensitivity: \(configuration.featureSensitivity)")
        print("  - Object Masking: \(configuration.isObjectMaskingEnabled)")
        
        return configuration
    }
    
    private func createPhotogrammetrySession(with configuration: PhotogrammetrySession.Configuration,
                                           imageDirectory: URL,
                                           outputFileName: String,
                                           options: ProcessingOptions) {
        
        // Reset state
        DispatchQueue.main.async {
            self.progress = 0.0
            self.generatedModelURL = nil
            self.errorMessage = nil
            self.isProcessing = true
            self.processingStage = "Initializing..."
        }
        
        do {
            session = try PhotogrammetrySession(input: imageDirectory, configuration: configuration)
            print("✅ Photogrammetry session created successfully")
            
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let finalOutputFileName = outputFileName.hasSuffix(".usdz") ? outputFileName : "\(outputFileName).usdz"
            currentOutputURL = documentsDirectory.appendingPathComponent(finalOutputFileName)
            
            guard let outputURL = currentOutputURL else {
                throw NSError(domain: "PhotogrammetryError", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Could not create output URL"])
            }
            
            // Remove existing file
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            
            // Start processing with memory management
            sessionTask = Task { @MainActor in
                do {
                    for try await output in session!.outputs {
                        if Task.isCancelled {
                            print("🛑 Processing cancelled")
                            self.isProcessing = false
                            return
                        }
                        
                        // Process output with autoreleasepool for memory management
                        autoreleasepool {
                            self.handleSessionOutput(output, for: outputURL)
                        }
                    }
                } catch {
                    self.errorMessage = "Processing error: \(error.localizedDescription)"
                    self.isProcessing = false
                    print("❌ Session error: \(error)")
                }
            }
            
            // Submit processing request
            let request = PhotogrammetrySession.Request.modelFile(url: outputURL, detail: options.detailLevel)
            try session?.process(requests: [request])
            
            DispatchQueue.main.async {
                self.processingStage = "Processing \(options.detailLevel) quality model..."
            }
            
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create session: \(error.localizedDescription)"
                self.isProcessing = false
            }
        }
    }
    
    private func handleSessionOutput(_ output: PhotogrammetrySession.Output, for expectedOutputURL: URL) {
        switch output {
        case .processingComplete:
            print("✅ Photogrammetry: Processing complete")
            validateAndFinalizeOutput(at: expectedOutputURL)
            
        case .requestError(let request, let error):
            handleProcessingError(request: request, error: error)
            
        case .requestComplete(let request, let result):
            handleRequestComplete(request: request, result: result)
            
        case .requestProgress(let request, let fractionComplete):
            updateProgress(for: request, progress: fractionComplete)
            
        case .inputComplete:
            DispatchQueue.main.async {
                self.processingStage = "All images processed, generating model..."
            }
            
        case .invalidSample(let id, let reason):
            print("⚠️ Invalid sample \(id): \(reason)")
            
        case .skippedSample(let id):
            print("⚠️ Skipped sample \(id)")
            
        case .automaticDownsampling:
            print("ℹ️ Automatic downsampling applied")
            DispatchQueue.main.async {
                self.processingStage = "Images automatically downsampled for processing"
            }
            
        @unknown default:
            print("⚠️ Unknown photogrammetry output: \(output)")
        }
    }
    
    private func updateProgress(for request: PhotogrammetrySession.Request, progress: Double) {
        DispatchQueue.main.async {
            self.progress = progress
            
            // Update stage based on progress
            if progress < 0.3 {
                self.processingStage = "Analyzing images..."
            } else if progress < 0.6 {
                self.processingStage = "Building 3D structure..."
            } else if progress < 0.9 {
                self.processingStage = "Generating textures..."
            } else {
                self.processingStage = "Finalizing model..."
            }
        }
    }
    
    private func handleProcessingError(request: PhotogrammetrySession.Request, error: Error) {
        let errorMessage = "Photogrammetry request failed: \(error.localizedDescription)"
        print("❌ Error: \(errorMessage)")
        print("📝 Request details: \(request)")
        
        let nsError = error as NSError
        print("📊 Error domain: \(nsError.domain)")
        print("📊 Error code: \(nsError.code)")
        
        // Provide more user-friendly error messages for common issues
        var userFriendlyMessage = error.localizedDescription
        if nsError.domain == "com.apple.photogrammetry.error" {
            switch nsError.code {
            case 3505:
                userFriendlyMessage = "Not enough visual features in the images. Try capturing more detailed images with better lighting and overlap."
            case 4011:
                userFriendlyMessage = "Processing failed. The images may be too similar, blurry, or lack sufficient overlap."
            default:
                break
            }
        }
        
        DispatchQueue.main.async {
            self.errorMessage = userFriendlyMessage
            self.isProcessing = false
        }
    }
    
    private func handleRequestComplete(request: PhotogrammetrySession.Request, result: PhotogrammetrySession.Result) {
        print("✅ Photogrammetry: Request complete for \(request).")
        if case .modelFile(let url) = result {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            print("📦 Generated model file at: \(url.path)")
            print("📏 File size: \(fileSize) bytes")
            
            if fileSize > 10_000 { // 10KB minimum for valid USDZ
                if validateUSDZFile(at: url) {
                    DispatchQueue.main.async {
                        self.generatedModelURL = url
                        self.progress = 1.0
                        self.isProcessing = false
                        self.processingStage = "Model generation complete!"
                        print("✅ Successfully completed USDZ generation")
                    }
                } else {
                    let errorMsg = "Generated file appears to be corrupted"
                    print("❌ Error: \(errorMsg)")
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        self.errorMessage = errorMsg
                        self.isProcessing = false
                    }
                }
            } else {
                let errorMsg = "Generated file is too small (\(fileSize) bytes). The photogrammetry process may not have had enough data."
                print("❌ Error: \(errorMsg)")
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    self.errorMessage = errorMsg
                    self.isProcessing = false
                }
            }
        } else {
            print("ℹ️ Photogrammetry: Request completed with result: \(result)")
        }
    }
    
    private func validateAndFinalizeOutput(at url: URL) {
        let fileManager = FileManager.default
        
        DispatchQueue.main.async {
            if fileManager.fileExists(atPath: url.path) {
                let fileSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                
                if fileSize > 10_000 { // 10KB minimum for valid USDZ
                    // Perform additional validation
                    if self.validateUSDZFile(at: url) {
                        self.generatedModelURL = url
                        self.processingStage = "Model generation complete!"
                        print("✅ Generated valid USDZ: \(fileSize/1024)KB")
                    } else {
                        self.errorMessage = "Generated file appears to be corrupted"
                        try? fileManager.removeItem(at: url)
                    }
                } else {
                    self.errorMessage = "Generated file is too small (\(fileSize) bytes)"
                    try? fileManager.removeItem(at: url)
                }
            } else {
                self.errorMessage = "Output file not found at expected location"
            }
            
            self.progress = 1.0
            self.isProcessing = false
        }
    }
    
    private func validateUSDZFile(at url: URL) -> Bool {
        // Basic USDZ validation
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            
            // Check for USD/USDZ magic bytes or ZIP signature
            let header = data.prefix(4)
            let zipSignature = Data([0x50, 0x4B, 0x03, 0x04]) // ZIP file signature
            let usdSignature = "PXR-".data(using: .ascii) ?? Data()
            
            return header == zipSignature || data.starts(with: usdSignature)
        } catch {
            print("❌ Error validating USDZ file: \(error)")
            return false
        }
    }
    
    func cancelProcessing() {
        print("Attempting to cancel photogrammetry processing...")
        sessionTask?.cancel()
        session = nil
        DispatchQueue.main.async {
            self.isProcessing = false
            self.progress = 0.0
            print("Photogrammetry processing cancelled by user.")
        }
    }
}
