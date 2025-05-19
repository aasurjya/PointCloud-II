import RealityKit
import Combine
import SwiftUI // For @Published and ObservableObject

@available(iOS 17.0, *)
class PhotogrammetryService: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var generatedModelURL: URL?
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false

    private var session: PhotogrammetrySession?
    private var currentOutputURL: URL?
    private var sessionTask: Task<Void, Error>? // Renamed to avoid conflict with Foundation.Task

    // Singleton for easier access if needed, or you can inject it.
    // static let shared = PhotogrammetryService()

    init() {}

    // Simplified API that always uses .reduced detail level
    func generateUSDZ(from imageDirectoryURL: URL, outputFileName: String) {
        // We're using .reduced as it's the only detail level we've confirmed exists
        let detailLevel = PhotogrammetrySession.Request.Detail.reduced
        
        print("📸 PhotogrammetryService: Starting USDZ generation")
        print("📁 Image directory: \(imageDirectoryURL.path)")
        
        // Get the parent directory (Scan_XXXXX directory)
        let scanDirectory = imageDirectoryURL.deletingLastPathComponent()
        print("🔍 Scan directory: \(scanDirectory.path)")
        
        // Check directory contents
        do {
            let fileManager = FileManager.default
            
            // First verify the directory exists and is accessible
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: imageDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                let errorMsg = "Image directory does not exist or is not a directory: \(imageDirectoryURL.path)"
                print("❌ \(errorMsg)")
                DispatchQueue.main.async {
                    self.errorMessage = errorMsg
                    self.isProcessing = false
                }
                return
            }
            
            // Get all image files
            let supportedExtensions = ["jpg", "jpeg", "png", "heic", "tiff"]
            let contents = try fileManager.contentsOfDirectory(at: imageDirectoryURL, 
                                                            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], 
                                                            options: [.skipsHiddenFiles])
            
            // Filter for image files and sort by name for consistent ordering
            let imageFiles = contents.filter { url in
                let ext = url.pathExtension.lowercased()
                return supportedExtensions.contains(ext)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            
            print("📊 Found \(imageFiles.count) image files in directory")
            
            // Check if we have enough images (minimum 3 for photogrammetry)
            if imageFiles.count < 3 {
                let errorMsg = "Insufficient images for photogrammetry. Found \(imageFiles.count) images, but need at least 3."
                print("❌ \(errorMsg)")
                DispatchQueue.main.async {
                    self.errorMessage = errorMsg
                    self.isProcessing = false
                }
                return
            }
            
            // Validate images before starting photogrammetry
            print("🔍 Validating input images...")
            var validImageCount = 0
            let minImageDimension: CGFloat = 640 // Minimum dimension for photogrammetry
            
            print("📋 Image validation results (first 5 images):")
            for (i, url) in imageFiles.prefix(5).enumerated() {
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                
                // Try to load the image
                if let image = UIImage(contentsOfFile: url.path) {
                    let size = image.size
                    let isValidSize = size.width >= minImageDimension && size.height >= minImageDimension
                    let isValidFileSize = fileSize > 1024 // At least 1KB
                    
                    if isValidSize && isValidFileSize {
                        validImageCount += 1
                        print("  ✅ \(i+1). \(url.lastPathComponent) (Valid: \(Int(size.width))x\(Int(size.height)), \(fileSize) bytes)")
                    } else {
                        print("  ⚠️ \(i+1). \(url.lastPathComponent) (Invalid: " +
                              "\(isValidSize ? "" : "Size too small \(Int(size.width))x\(Int(size.height)) " )" +
                              "\(isValidFileSize ? "" : "File too small \(fileSize) bytes")")
                    }
                } else {
                    print("  ❌ \(i+1). \(url.lastPathComponent) (Failed to load image)")
                }
            }
            
            // Check if we have enough valid images
            let minValidImages = 5 // Minimum number of valid images needed
            if validImageCount < minValidImages {
                let errorMsg = "Insufficient valid images. Found \(validImageCount) valid images, but need at least \(minValidImages)."
                print("❌ \(errorMsg)")
                throw NSError(domain: "PhotogrammetryError", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: errorMsg,
                    NSLocalizedRecoverySuggestionErrorKey: "Please ensure you have at least \(minValidImages) clear, well-lit images with sufficient overlap."
                ])
            }
            
            print("ℹ️ Starting photogrammetry session with \(validImageCount) valid images")
            print("ℹ️ Using sample ordering: unordered")
            
            // Create photogrammetry session configuration
            var configuration = PhotogrammetrySession.Configuration()
            configuration.sampleOrdering = .unordered
            
            print("🔄 Creating photogrammetry session...")
            let session: PhotogrammetrySession
            
            do {
                // Create a session with the configuration
                print("📊 Initializing PhotogrammetrySession with input directory: \(imageDirectoryURL.path)")
                session = try PhotogrammetrySession(input: imageDirectoryURL, 
                                                 configuration: configuration)
                print("✅ Successfully created photogrammetry session")
                
                // Log session configuration
                print("📋 Session Configuration:")
                print("  - Sample Ordering: \(configuration.sampleOrdering)")
                print("  - Feature Sensitivity: \(configuration.featureSensitivity)")
                
            } catch let error as NSError {
                var errorMsg = "Failed to create photogrammetry session: \(error.localizedDescription)"
                var recoverySuggestion = "Please try again with different images."
                
                // Provide more specific error messages for common issues
                if error.domain == "com.apple.photogrammetry.error" {
                    switch error.code {
                    case 1: // Invalid input
                        errorMsg = "Invalid input directory or images"
                        recoverySuggestion = "Please check that the input directory contains valid image files."
                    case 2: // Unsupported format
                        errorMsg = "Unsupported image format"
                        recoverySuggestion = "Please use JPG or PNG images with standard color spaces."
                    case 3: // Insufficient features
                        errorMsg = "Insufficient image features"
                        recoverySuggestion = "Try capturing more detailed images with better lighting and overlap."
                    default:
                        break
                    }
                }
                
                print("❌ \(errorMsg)")
                print("📊 Error domain: \(error.domain)")
                print("📊 Error code: \(error.code)")
                
                throw NSError(domain: error.domain, code: error.code, userInfo: [
                    NSLocalizedDescriptionKey: errorMsg,
                    NSLocalizedRecoverySuggestionErrorKey: recoverySuggestion,
                    NSUnderlyingErrorKey: error
                ])
            }
            
            // Store the session
            self.session = session
            
        } catch {
            let errorMsg = "❌ Error creating photogrammetry session: \(error.localizedDescription)"
            print(errorMsg)
            DispatchQueue.main.async {
                self.errorMessage = errorMsg
                self.isProcessing = false
            }
            return
        }
        
        // Continue with the implementation
        guard PhotogrammetrySession.isSupported else {
            let errorMsg = "Photogrammetry is not supported on this device or OS version."
            print("❌ \(errorMsg)")
            DispatchQueue.main.async {
                self.errorMessage = errorMsg
                self.isProcessing = false
            }
            return
        }

        // Reset state
        DispatchQueue.main.async {
            self.progress = 0.0
            self.generatedModelURL = nil
            self.errorMessage = nil
            self.isProcessing = true
        }

        var configuration = PhotogrammetrySession.Configuration()
        // Configure detail level, sample ordering etc. if needed
        // configuration.sampleOrdering = .sequential // if images are named sequentially and in order
        // configuration.featureSensitivity = .normal
        // configuration.isObjectMaskingEnabled = false // if you don't have object masks

        print("PhotogrammetryService: Attempting to create session with input directory: \(imageDirectoryURL.path)")
        var isDirectory: ObjCBool = false
        let directoryExists = FileManager.default.fileExists(atPath: imageDirectoryURL.path, isDirectory: &isDirectory)
        print("PhotogrammetryService: Input directory exists: \(directoryExists), Is a directory: \(isDirectory.boolValue)")
        
        if directoryExists && isDirectory.boolValue {
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: imageDirectoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                print("PhotogrammetryService: Directory contents (first 10): \(contents.map { $0.lastPathComponent }.prefix(10))")
                if contents.isEmpty {
                    print("PhotogrammetryService: WARNING - Input directory is empty!")
                }
            } catch {
                print("PhotogrammetryService: Error listing directory contents: \(error)")
            }
        } else {
            print("PhotogrammetryService: WARNING - Input directory does not exist or is not a directory.")
        }

        do {
            // print("Initializing PhotogrammetrySession with input: \(imageDirectoryURL.path)") // Already printed above
            session = try PhotogrammetrySession(input: imageDirectoryURL, configuration: configuration)
            print("PhotogrammetryService: Session successfully initialized.")
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create PhotogrammetrySession: \(error.localizedDescription)"
                self.isProcessing = false
            }
            print("Error creating PhotogrammetrySession: \(error)")
            return
        }

        guard let session = session else {
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // Ensure the output file name has .usdz extension
        let finalOutputFileName = outputFileName.hasSuffix(".usdz") ? outputFileName : "\(outputFileName).usdz"
        currentOutputURL = documentsDirectory.appendingPathComponent(finalOutputFileName)
        
        guard let outputURL = currentOutputURL else {
            DispatchQueue.main.async {
                self.errorMessage = "Could not construct output URL."
                self.isProcessing = false
            }
            return
        }

        // Delete existing file if any, to prevent PhotogrammetrySession from potentially failing or appending
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
                print("Removed existing file at: \(outputURL.path)")
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to remove existing output file: \(error.localizedDescription)"
                    self.isProcessing = false
                }
                print("Error removing existing file: \(error)")
                return
            }
        }
        
        print("Photogrammetry session configured. Output will be at: \(outputURL.path)")

        sessionTask = Task {
            do {
                print("Starting to iterate through session outputs.")
                for try await output in session.outputs {
                    if Task.isCancelled {
                        print("Photogrammetry task cancelled during output processing.")
                        DispatchQueue.main.async { self.isProcessing = false }
                        return
                    }
                    handleSessionOutput(output, for: outputURL)
                }
                print("Finished iterating session outputs.")
                // If the loop finishes without .processingComplete or .requestComplete with a URL, it might be an issue.
                // However, .processingComplete should be the final state for a successful run with .modelFile request.
            } catch {
                print("Photogrammetry session error during output processing: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorMessage = "Session error: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }

        // Start processing by requesting the model file
        do {
            let request = PhotogrammetrySession.Request.modelFile(url: outputURL, detail: detailLevel)
            print("Submitting modelFile request to session for URL: \(outputURL.path) with detail: \(detailLevel)")
            try session.process(requests: [request])
        } catch {
            print("Failed to submit processing request: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to start processing: \(error.localizedDescription)"
                self.isProcessing = false
            }
        }
    }

    private func handleSessionOutput(_ output: PhotogrammetrySession.Output, for expectedOutputURL: URL) {
        switch output {
        case .processingComplete:
            print("Photogrammetry: Processing complete.")
            // This case indicates all requests are done.
            // Check if the output file exists and is valid
            let fileManager = FileManager.default
            
            DispatchQueue.main.async {
                if fileManager.fileExists(atPath: expectedOutputURL.path) {
                    let fileSize = (try? fileManager.attributesOfItem(atPath: expectedOutputURL.path)[.size] as? Int64) ?? 0
                    print("✅ Output file exists at \(expectedOutputURL.path)")
                    print("📦 File size: \(fileSize) bytes")
                    
                    if fileSize > 1024 { // 1KB minimum size for a valid USDZ file
                        self.generatedModelURL = expectedOutputURL
                        print("✅ Successfully generated USDZ model")
                    } else {
                        self.errorMessage = "Generated file is too small (\(fileSize) bytes). The photogrammetry process may not have had enough data."
                        print("❌ Error: \(self.errorMessage!)")
                        // Clean up the invalid file
                        try? fileManager.removeItem(at: expectedOutputURL)
                    }
                } else {
                    self.errorMessage = "Processing complete, but output file not found at expected location."
                    print("❌ Error: \(self.errorMessage!)")
                    
                    // Check if there's a temporary file that might contain error information
                    let tempDir = fileManager.temporaryDirectory
                    do {
                        let tempFiles = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                        let logFiles = tempFiles.filter { $0.pathExtension == "log" }
                        
                        if !logFiles.isEmpty {
                            print("🔍 Found log files that might contain error information:")
                            for logFile in logFiles.prefix(3) {
                                print(" - \(logFile.lastPathComponent)")
                                if let logContents = try? String(contentsOf: logFile, encoding: .utf8) {
                                    print("   Last 3 lines:\n" + logContents.components(separatedBy: "\n").suffix(3).joined(separator: "\n"))
                                }
                            }
                        }
                    } catch {
                        print("⚠️ Could not check for log files: \(error.localizedDescription)")
                    }
                }
                
                self.progress = 1.0
                self.isProcessing = false
            }

        case .requestError(let request, let error):
            let errorMessage = "Photogrammetry request failed: \(error.localizedDescription)"
            print("❌ Error: \(errorMessage)")
            print("📝 Request details: \(request)")
            
            // Log additional error information if available
            let nsError = error as NSError
            print("📊 Error domain: \(nsError.domain)")
            print("📊 Error code: \(nsError.code)")
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("📊 Underlying error: \(underlyingError.localizedDescription)")
                print("📊 Underlying error domain: \(underlyingError.domain)")
                print("📊 Underlying error code: \(underlyingError.code)")
            }
            
            // Provide more user-friendly error messages for common issues
            var userFriendlyMessage = error.localizedDescription
            if nsError.domain == "com.apple.photogrammetry.error" {
                switch nsError.code {
                case 3505: // Common error code for insufficient features
                    userFriendlyMessage = "Not enough visual features in the images. Try capturing more detailed images with better lighting and overlap."
                case 4011: // Common error code for processing failure
                    userFriendlyMessage = "Processing failed. The images may be too similar, blurry, or lack sufficient overlap."
                default:
                    break
                }
            }
            
            DispatchQueue.main.async {
                self.errorMessage = userFriendlyMessage
                self.isProcessing = false
            }

        case .requestComplete(let request, let result):
            print("✅ Photogrammetry: Request complete for \(request).")
            if case .modelFile(let url) = result {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                print("📦 Generated model file at: \(url.path)")
                print("📏 File size: \(fileSize) bytes")
                
                if fileSize > 1024 { // 1KB minimum size for a valid USDZ file
                    DispatchQueue.main.async {
                        self.generatedModelURL = url
                        self.progress = 1.0
                        self.isProcessing = false
                        print("✅ Successfully completed USDZ generation")
                    }
                } else {
                    let errorMsg = "Generated file is too small (\(fileSize) bytes). The photogrammetry process may not have had enough data."
                    print("❌ Error: \(errorMsg)")
                    try? FileManager.default.removeItem(at: url) // Clean up invalid file
                    DispatchQueue.main.async {
                        self.errorMessage = errorMsg
                        self.isProcessing = false
                    }
                }
            } else {
                print("ℹ️ Photogrammetry: Request completed with result: \(result)")
            }

        case .requestProgress(let request, let fractionComplete):
            // print("Photogrammetry: Progress for \(request): \(fractionComplete)") // Can be very verbose
            DispatchQueue.main.async {
                self.progress = fractionComplete
            }

        case .inputComplete:
            print("Photogrammetry: All input images have been consumed.")

        case .invalidSample(let id, let reason):
            print("Photogrammetry: Invalid sample ID \(id), reason: \(reason)")
            // Optionally, collect these to inform the user, but don't stop processing for one bad image.

        case .skippedSample(let id):
            print("Photogrammetry: Skipped sample ID \(id).")

        case .automaticDownsampling:
            print("Photogrammetry: Automatic downsampling was applied to input images.")
            
        @unknown default:
            print("Photogrammetry: Received an unknown PhotogrammetrySession.Output case.")
        }
    }

    func cancelProcessing() {
        print("Attempting to cancel photogrammetry processing...")
        sessionTask?.cancel()
        session = nil // Release the session reference, it will tear itself down.
        DispatchQueue.main.async {
            self.isProcessing = false
            self.progress = 0.0
            // Don't clear errorMessage or generatedModelURL here, user might want to see the last state.
            print("Photogrammetry processing cancelled by user.")
        }
    }
    
    // Helper to provide a description for the request type (optional)
    // private func description(for request: PhotogrammetrySession.Request) -> String {
    //     switch request.type {
    //     case .modelFile: return "ModelFile"
    //     // Add other cases if you use other request types
    //     default: return "UnknownRequestType"
    //     }
    // }
}
