// ContentView.swift
// PointCloudV3
// Updated for high-accuracy mesh reconstruction with colorful point cloud, fixing ARKit errors
// Further refined with improved frame capture, bilinear interpolation, and projection accuracy.
// Key changes: Consistent use of ARCamera.projectPoint in sampleColor and option for higher res video.

import SwiftUI
import RealityKit
import ARKit
import CoreImage
import AVFoundation
import simd

// MARK: - View Model
class ARViewModel: ObservableObject {
    @Published var arView: ARView?
    var coordinator: ARSessionDelegateCoordinator?
    @Published var scanStatus: ScanStatus = .idle
    @Published var progressMessage: String = ""
    
    enum ScanStatus {
        case idle
        case scanning
        case processing
        case completed
        case error
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var arViewModel = ARViewModel()
    @State private var showBrowser = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var scanningTimer: Int = 0
    @State private var timerRunning = false
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ARViewContainer()
                .edgesIgnoringSafeArea(.all)
                .environmentObject(arViewModel)

            VStack {
                Spacer()
                
                if arViewModel.scanStatus == .idle {
                    Button(action: startScanning) {
                        Text("Start Scanning")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding()
                } else if arViewModel.scanStatus == .scanning {
                    VStack {
                        Text("Scanning: \(scanningTimer)s")
                            .font(.headline)
                            .padding()
                            .onReceive(timer) { _ in
                                if timerRunning {
                                    scanningTimer += 1
                                }
                            }
                        
                        Button(action: finishScanning) {
                            Text("Finish & Process Scan")
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .padding(.bottom, 8)
                        
                        Button(action: cancelScanning) {
                            Text("Cancel")
                                .padding()
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                } else if arViewModel.scanStatus == .processing {
                    VStack {
                        ProgressView()
                            .padding()
                        Text(arViewModel.progressMessage)
                            .padding()
                    }
                } else if arViewModel.scanStatus == .completed {
                    VStack {
                        Text("Scan Complete!")
                            .font(.headline)
                            .padding()
                        
                        Button(action: {
                            arViewModel.scanStatus = .idle
                            scanningTimer = 0
                            arViewModel.coordinator?.clearAnchors()
                            arViewModel.coordinator?.clearFrames()
                            if let arView = arViewModel.arView, let config = arView.session.configuration {
                                arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                            }
                        }) {
                            Text("New Scan")
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .padding(.bottom, 8)
                        
                        Button(action: { showBrowser.toggle() }) {
                            Text("Browse Meshes")
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showBrowser) {
            FileBrowserView()
                .environmentObject(arViewModel)
        }
        .alert(isPresented: $showError) {
            Alert(
                title: Text("Error"),
                message: Text(errorMessage ?? "Unknown error"),
                dismissButton: .default(Text("OK")) {
                    arViewModel.scanStatus = .idle
                }
            )
        }
    }

    private func setExposure(locked: Bool) {
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("Failed to get video device.")
            return
        }
        do {
            try device.lockForConfiguration()
            if locked {
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                    print("Exposure locked.")
                } else {
                     print("Exposure lock not supported.")
                }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    print("Exposure set to continuous auto.")
                } else {
                    print("Continuous auto exposure not supported.")
                }
            }
            device.unlockForConfiguration()
        } catch {
            print("Failed to \(locked ? "lock" : "unlock") exposure: \(error.localizedDescription)")
        }
    }

    private func startScanning() {
        setExposure(locked: true)
        
        arViewModel.coordinator?.clearAnchors()
        arViewModel.coordinator?.clearFrames()
        arViewModel.scanStatus = .scanning
        scanningTimer = 0
        timerRunning = true
        
        arViewModel.coordinator?.startCollectingFrames()
    }
    
    private func cancelScanning() {
        setExposure(locked: false)
        
        arViewModel.coordinator?.stopCollectingFrames()
        arViewModel.scanStatus = .idle
        timerRunning = false
        scanningTimer = 0
        arViewModel.coordinator?.clearAnchors()
        arViewModel.coordinator?.clearFrames()
        if let arView = arViewModel.arView, let config = arView.session.configuration {
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    private func finishScanning() {
        guard let arView = arViewModel.arView,
              let coord = arViewModel.coordinator else {
            errorMessage = "ARView/session not ready"
            showError = true
            arViewModel.scanStatus = .error
            return
        }
        
        setExposure(locked: false)
        
        coord.stopCollectingFrames()
        timerRunning = false
        arViewModel.scanStatus = .processing
        arViewModel.progressMessage = "Processing scan data..."

        Task {
            guard !coord.meshAnchors.isEmpty else {
                await MainActor.run {
                    errorMessage = "No mesh data captured. Try scanning longer and moving around the environment."
                    showError = true
                    arViewModel.scanStatus = .idle
                }
                return
            }
            
            guard !coord.capturedFrames.isEmpty else {
                await MainActor.run {
                    errorMessage = "No camera frames captured. This is unexpected if mesh data exists. Check frame capture logic."
                    showError = true
                    arViewModel.scanStatus = .idle
                }
                return
            }

            await MainActor.run {
                arView.session.pause()
                arViewModel.progressMessage = "Exporting textured mesh..."
            }

            coord.exportColoredPointCloud()
            
            await MainActor.run {
                arViewModel.scanStatus = .completed
                arViewModel.progressMessage = "Scan complete. Ready for new scan or Browse."
            }
        }
    }
}

// MARK: - ARView Container
struct ARViewContainer: UIViewRepresentable {
    @EnvironmentObject var arViewModel: ARViewModel

    func makeCoordinator() -> ARSessionDelegateCoordinator {
        let coord = ARSessionDelegateCoordinator(arViewModel: arViewModel)
        arViewModel.coordinator = coord
        return coord
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arViewModel.arView = arView

        var config = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        } else {
            print("❌ Device does not support scene reconstruction .mesh")
        }
        config.planeDetection = [.horizontal, .vertical]

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
             config.frameSemantics.insert(.sceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else {
            print("❌ Device does not support any scene depth frame semantics.")
        }
        
        config.wantsHDREnvironmentTextures = true
        config.isLightEstimationEnabled = true
        config.environmentTexturing = .automatic
        
        // CORRECTED: Safely unwrap optional video format
        if #available(iOS 16.0, *) {
            if let recommendedFormat = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
                config.videoFormat = recommendedFormat
                print("Using recommended high-resolution video format.")
            } else if let recommended4KFormat = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution { // Fallback option
                config.videoFormat = recommended4KFormat
                print("Using recommended 4K video format.")
            } else {
                print("No specific high-resolution or 4K video format available/recommended. Using default.")
            }
        }


        arView.session.run(config)
        arView.session.delegate = context.coordinator
        
         arView.debugOptions = [.showSceneUnderstanding, .showWorldOrigin, .showFeaturePoints]

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Captured Frame
struct CapturedFrame {
    let image: CGImage
    let camera: ARCamera
    let timestamp: TimeInterval
    
    var debugName: String {
        return "Frame_\(Int(timestamp * 1000))"
    }
}

// MARK: - AR Session Delegate
class ARSessionDelegateCoordinator: NSObject, ARSessionDelegate {
    var meshAnchors = [ARMeshAnchor]()
    var planeAnchors = [ARPlaneAnchor]()
    var capturedFrames = [CapturedFrame]()
    var enhancedFrames = [EnhancedCapturedFrame]()
    
    private var collectingFrames = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    private var lastFrameCaptureTime: TimeInterval = 0
    private let desiredFrameCaptureInterval: TimeInterval = 0.1 // ~10 FPS

    private weak var arViewModel: ARViewModel?
    
    // New storage and capture components
    private var scanStorage: ScanStorage? = nil
    private var frameCapture: EnhancedFrameCapture? = nil
    private var currentScanId: String? = nil
    private var pointCloudGenerator: DensePointCloudGenerator? = nil
    private var isRecoveredScan: Bool = false

    init(arViewModel: ARViewModel) {
        self.arViewModel = arViewModel
        
        // Initialize enhanced frame capture
        self.frameCapture = EnhancedFrameCapture(captureHighRes: true, captureDepth: true)
    }

    func clearAnchors() {
        meshAnchors.removeAll()
        planeAnchors.removeAll()
        print("Cleared all anchors.")
    }
    
    func clearFrames() {
        capturedFrames.removeAll()
        enhancedFrames.removeAll()
        print("Cleared all captured frames.")
        
        // Close current storage if active
        scanStorage?.closeCurrentScan()
        scanStorage = nil
        currentScanId = nil
        isRecoveredScan = false
    }
    
    /// Recover a scan from storage
    func recoverScan(storage: ScanStorage, scanId: String) {
        // Store the references
        self.scanStorage = storage
        self.currentScanId = scanId
        self.isRecoveredScan = true
        
        // Set the storage for frame capture
        frameCapture?.setStorage(storage)
        
        // Initialize the point cloud generator
        pointCloudGenerator = DensePointCloudGenerator()
        
        // Start collecting new frames again
        collectingFrames = true
        lastFrameCaptureTime = 0
        
        print("✅ Recovered scan: \(scanId)")
    }
    
    func startCollectingFrames() {
        collectingFrames = true
        lastFrameCaptureTime = 0
        
        // Create new storage for this scan
        let storage = ScanStorage()
        let scanId = storage.startNewScan()
        scanStorage = storage
        currentScanId = scanId
        
        // Set storage for frame capture
        frameCapture?.setStorage(storage)
        
        // Initialize point cloud generator
        pointCloudGenerator = DensePointCloudGenerator()
        
        print("Started collecting frames with continuous storage. Scan ID: \(scanId)")
    }
    
    func stopCollectingFrames() {
        collectingFrames = false
        print("Stopped collecting frames. Total frames: \(capturedFrames.count), Enhanced frames: \(enhancedFrames.count)")
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if collectingFrames {
            if frame.timestamp - lastFrameCaptureTime >= desiredFrameCaptureInterval {
                // Create a local copy of the frame to avoid retaining ARFrame
                autoreleasepool {
                    // Use both methods for compatibility
                    captureCurrentFrame(from: frame)
                    
                    // Also use enhanced frame capture
                    if let enhancedFrame = frameCapture?.captureEnhancedFrame(from: frame) {
                        enhancedFrames.append(enhancedFrame)
                        
                        // Limit the number of stored enhanced frames
                        while enhancedFrames.count > 30 {
                            enhancedFrames.removeFirst()
                        }
                    }
                    
                    lastFrameCaptureTime = frame.timestamp
                }
            }
        }
        
        // Help prevent retention of ARFrames
        // Note: We can't directly clear capturedImage as it's read-only
        // Instead, we rely on autorelease pool and limited frame storage
    }
    
    private func captureCurrentFrame(from arFrame: ARFrame) {
        guard collectingFrames else { return }
        
        // Use autoreleasepool to ensure immediate memory cleanup
        autoreleasepool {
            // Immediately store to disk if we have storage available instead of keeping in memory
            if let storage = scanStorage {
                // Create a downsampled image for memory efficiency but retain quality
                let pixelBuffer = arFrame.capturedImage
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                
                // Process the image in a way that doesn't consume too much memory
                // Use lower quality for preview, higher for storage
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let options: [CIContextOption: Any] = [
                    .useSoftwareRenderer: true,            // Use CPU instead of GPU
                    .workingColorSpace: colorSpace,        // Ensure consistent color space
                    .cacheIntermediates: false,            // Don't cache intermediate results
                    .highQualityDownsample: false          // Use faster downsampling
                ]
                
                // Create a CIContext - CIContext initializer returns non-optional
                let localCIContext = CIContext(options: options)
                
                // Create the CGImage which can be optional
                guard let cgImage = localCIContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace) else {
                    print("❌ Failed to convert camera image for \(arFrame.timestamp)")
                    return
                }
                
                let newCapturedFrame = CapturedFrame(
                    image: cgImage,
                    camera: arFrame.camera,
                    timestamp: arFrame.timestamp
                )
                
                // Save directly to storage on a background thread
                DispatchQueue.global(qos: .utility).async {
                    autoreleasepool {
                        storage.saveFrame(newCapturedFrame)
                    }
                }
                
                // Keep only the absolute minimum frames in memory for UI purposes
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.capturedFrames.count >= 5 {
                        self.capturedFrames.removeFirst(self.capturedFrames.count - 4) // Only keep latest 5
                    }
                    self.capturedFrames.append(newCapturedFrame)
                }
            } else {
                // Fallback to memory-only storage with an extremely strict limit
                let pixelBuffer = arFrame.capturedImage
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                
                // Use a local context to avoid keeping resources around
                let localCIContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
                
                guard let cgImage = localCIContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
                    print("❌ Failed to convert camera image for \(arFrame.timestamp)")
                    return
                }
                
                let newCapturedFrame = CapturedFrame(
                    image: cgImage,
                    camera: arFrame.camera,
                    timestamp: arFrame.timestamp
                )
                
                if capturedFrames.count >= 10 {
                    capturedFrames.removeFirst(capturedFrames.count - 9) // Only keep latest 10
                }
                capturedFrames.append(newCapturedFrame)
            }
        }
        
        // Force a memory cleanup every 10 frames
        if frameCounter % 10 == 0 {
            DispatchQueue.global(qos: .utility).async {
                autoreleasepool {
                    // This empty autoreleasepool helps clean up memory
                }
            }
        }
        frameCounter += 1
    }
    
    private var frameCounter: Int = 0
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                meshAnchors.append(meshAnchor)
                
                // Also save to continuous storage
                scanStorage?.saveMeshAnchor(meshAnchor)
            } else if let planeAnchor = anchor as? ARPlaneAnchor {
                planeAnchors.append(planeAnchor)
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor,
               let index = meshAnchors.firstIndex(where: { $0.identifier == meshAnchor.identifier }) {
                meshAnchors[index] = meshAnchor
            } else if let planeAnchor = anchor as? ARPlaneAnchor,
                      let index = planeAnchors.firstIndex(where: { $0.identifier == planeAnchor.identifier }) {
                planeAnchors[index] = planeAnchor
            }
        }
    }

    private func bestFrameForPoint(_ point: SIMD3<Float>, worldNormal: SIMD3<Float>?) -> CapturedFrame? {
        guard !capturedFrames.isEmpty else { return nil }
        if capturedFrames.count == 1 { return capturedFrames.first }

        var bestScore: Float = -Float.greatestFiniteMagnitude
        var bestFrame: CapturedFrame? = nil

        for frame in capturedFrames {
            let cameraTransform = frame.camera.transform
            let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            let pointToCamera = normalize(cameraPosition - point)
            var score: Float = 1.0 / (distance(cameraPosition, point) + 0.01)
            
            if let normal = worldNormal {
                let alignment = dot(pointToCamera, normal)
                score *= max(0.1, alignment)
            }
            
            let imageWidthCG: CGFloat = CGFloat(frame.image.width)    // CGFloat
            let imageHeightCG: CGFloat = CGFloat(frame.image.height)  // CGFloat
            
            let projectedPoint = frame.camera.projectPoint(point,
                                                           orientation: .landscapeRight,
                                                           viewportSize: CGSize(width: imageWidthCG, height: imageHeightCG))

            // projectedPoint.x and .y are CGFloat here
            if projectedPoint.x < 0 || projectedPoint.y < 0 ||
               projectedPoint.x >= imageWidthCG || projectedPoint.y >= imageHeightCG { // Compare CGFloat with CGFloat
                score *= 0.05
            } else {
                // CORRECTED: Ensure all calculations for centerDist use Float consistently
                let projectedX_Float = Float(projectedPoint.x)
                let projectedY_Float = Float(projectedPoint.y)
                let imageWidth_Float = Float(imageWidthCG)
                let imageHeight_Float = Float(imageHeightCG)

                let dx = projectedX_Float - imageWidth_Float / 2
                let dy = projectedY_Float - imageHeight_Float / 2
                let centerDist = sqrt(dx*dx + dy*dy) // dx, dy are Float, centerDist is Float
                score *= (1.0 - min(0.5, centerDist / (max(imageWidth_Float, imageHeight_Float)))) // All Floats here
            }

            if score > bestScore {
                bestScore = score
                bestFrame = frame
            }
        }
        return bestFrame ?? capturedFrames.last
    }
    
    private func sampleColor(worldPoint: SIMD3<Float>, frame: CapturedFrame) -> SIMD3<UInt8> {
        let camera = frame.camera
        let imageWidthCG = CGFloat(frame.image.width)   // This is CGFloat
        let imageHeightCG = CGFloat(frame.image.height) // This is CGFloat

        let projectedPt = camera.projectPoint(worldPoint,
                                              orientation: .landscapeRight,
                                              viewportSize: CGSize(width: imageWidthCG, height: imageHeightCG))
        
        let pointInCameraSpace = camera.transform.inverse * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        if pointInCameraSpace.z >= 0 {
            return SIMD3<UInt8>(128, 128, 128)
        }

        // CORRECTED: Convert projectedPt components (CGFloat) to Float
        let u_exact = Float(projectedPt.x)
        let v_exact = Float(projectedPt.y)

        // CORRECTED: Compare u_exact (Float) with Float versions of image dimensions
        if u_exact < 0 || u_exact >= Float(imageWidthCG) - 1 || v_exact < 0 || v_exact >= Float(imageHeightCG) - 1 {
            return SIMD3<UInt8>(128, 128, 128)
        }

        guard let dataProvider = frame.image.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else {
            print("❌ Failed to get image data for \(frame.debugName) during color sampling.")
            return SIMD3<UInt8>(128, 128, 128)
        }

        let bytesPerRow = frame.image.bytesPerRow
        let bytesPerPixel = frame.image.bitsPerPixel / 8
        if bytesPerPixel != 4 {
            print("Warning: Expected 4 bytes per pixel (RGBA), got \(bytesPerPixel) for \(frame.debugName)")
            return SIMD3<UInt8>(100,100,100);
        }

        let x0 = Int(floor(u_exact))
        let y0 = Int(floor(v_exact))

        let u_ratio = u_exact - Float(x0)
        let v_ratio = v_exact - Float(y0)
        let u_opposite = 1 - u_ratio
        let v_opposite = 1 - v_ratio

        func getColorComponentAt(x: Int, y: Int, componentOffset: Int) -> Float {
            let offset = y * bytesPerRow + x * bytesPerPixel + componentOffset
            guard offset < CFDataGetLength(data) && offset >= 0 else { // Added check for offset >= 0
                print("Warning: Calculated offset \(offset) is out of bounds for image data of length \(CFDataGetLength(data)). Frame: \(frame.debugName), Point: (\(x),\(y))")
                return 128.0
            }
            return Float(ptr[offset])
        }

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

        let r_top = r00 * u_opposite + r10 * u_ratio
        let r_bottom = r01 * u_opposite + r11 * u_ratio
        let final_r = r_top * v_opposite + r_bottom * v_ratio

        let g_top = g00 * u_opposite + g10 * u_ratio
        let g_bottom = g01 * u_opposite + g11 * u_ratio
        let final_g = g_top * v_opposite + g_bottom * v_ratio

        let b_top = b00 * u_opposite + b10 * u_ratio
        let b_bottom = b01 * u_opposite + b11 * u_ratio
        let final_b = b_top * v_opposite + b_bottom * v_ratio
        
        return SIMD3<UInt8>(UInt8(clamping: Int(round(final_r))),
                               UInt8(clamping: Int(round(final_g))),
                               UInt8(clamping: Int(round(final_b))))
    }
    
    func exportColoredPointCloud() {
        arViewModel?.progressMessage = "Preparing to export... Mesh Anchors: \(meshAnchors.count), Frames: \(capturedFrames.count)"
        print("Starting export with \(meshAnchors.count) mesh anchors and \(capturedFrames.count) frames.")
        
        guard !meshAnchors.isEmpty else {
            print("❌ No mesh anchors collected. Cannot export point cloud.")
            arViewModel?.progressMessage = "Error: No mesh data."
            return
        }
        
        // First check if we have enhanced frames available
        let framesAvailable = !enhancedFrames.isEmpty || !capturedFrames.isEmpty
        guard framesAvailable else {
            print("❌ No frames collected. Cannot color point cloud.")
            arViewModel?.progressMessage = "Error: No camera frames for texturing."
            return
        }
        
        // Use the dense point cloud generator if available
        if let generator = pointCloudGenerator, let storage = scanStorage {
            Task {
                // Set up progress callback
                generator.setProgressCallback { [weak self] message, progress in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.arViewModel?.progressMessage = message
                    }
                }
                
                // Create output file name
                let timestamp = Int(Date().timeIntervalSince1970)
                let fileName = "DensePointCloud_\(timestamp).ply"
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileURL = documentsDirectory.appendingPathComponent(fileName)
                
                // Get frames from the appropriate source (enhanced or regular)
                let frames = !capturedFrames.isEmpty ? capturedFrames : enhancedFrames.map { enhancedFrame in
                    return CapturedFrame(
                        image: enhancedFrame.highResImage ?? enhancedFrame.originalImage,
                        camera: enhancedFrame.camera,
                        timestamp: enhancedFrame.timestamp
                    )
                }
                
                // Generate the dense point cloud
                let success = await generator.generatePointCloud(
                    meshAnchors: meshAnchors,
                    frames: frames,
                    outputURL: fileURL
                )
                
                if success {
                    await MainActor.run {
                        print("✅ Saved dense point cloud to \(fileURL.lastPathComponent)")
                        arViewModel?.progressMessage = "Exported dense point cloud to \(fileName)"
                        
                        // Close scan data to finalize
                        storage.closeCurrentScan()
                    }
                } else {
                    await MainActor.run {
                        print("❌ Failed to generate dense point cloud")
                        arViewModel?.progressMessage = "Error: Failed to generate point cloud"
                        
                        // Fall back to legacy method
                        self.legacyExportColoredPointCloud()
                    }
                }
            }
        } else {
            // Fall back to the original method if new components aren't available
            legacyExportColoredPointCloud()
        }
    }
    
    /// Legacy point cloud export method (for backward compatibility)
    private func legacyExportColoredPointCloud() {
        arViewModel?.progressMessage = "Using legacy export... Mesh Anchors: \(meshAnchors.count), Frames: \(capturedFrames.count)"
        print("Starting legacy export with \(meshAnchors.count) mesh anchors and \(capturedFrames.count) frames.")

        var verticesWithColor = [(position: SIMD3<Float>, color: SIMD3<UInt8>)]()
        var defaultColorCount = 0
        var totalVerticesProcessed = 0

        for (anchorIndex, anchor) in meshAnchors.enumerated() {
            arViewModel?.progressMessage = "Processing anchor \(anchorIndex + 1)/\(meshAnchors.count)..."
            let geometry = anchor.geometry // This is ARMeshGeometry
            let transform = anchor.transform

            // Extract vertices
            let vertices = geometry.vertices // This is ARGeometrySource
            let verticesBuffer = vertices.buffer.contents() // MTLBuffer contents, advance by offset
            let verticesOffset = vertices.offset // Offset for this source in the MTLBuffer
            let verticesStride = vertices.stride
            var localVertices = [SIMD3<Float>]()
            for i in 0..<vertices.count {
                let vertexPointer = verticesBuffer.advanced(by: verticesOffset + i * verticesStride)
                localVertices.append(vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
            }
            totalVerticesProcessed += localVertices.count

            // Extract faces
            let faces = geometry.faces // This is ARGeometryElement
            let facesBuffer = faces.buffer.contents() // MTLBuffer contents for faces
            let indicesPerFace = faces.indexCountPerPrimitive
            var parsedFaces = [[Int]]()
            if faces.bytesPerIndex == 4 {
                 for i in 0..<faces.count { // faces.count is the number of primitives (triangles)
                    var faceIndices = [Int]()
                    for j in 0..<indicesPerFace { // indicesPerFace is usually 3
                        // Calculate byte offset from the start of the facesBuffer
                        let byteOffset = (i * indicesPerFace + j) * MemoryLayout<UInt32>.size
                        let indexPointer = facesBuffer.advanced(by: byteOffset)
                        faceIndices.append(Int(indexPointer.assumingMemoryBound(to: UInt32.self).pointee))
                    }
                    parsedFaces.append(faceIndices)
                }
            } else if faces.bytesPerIndex == 2 { // Handle UInt16 indices as well
                 for i in 0..<faces.count {
                    var faceIndices = [Int]()
                    for j in 0..<indicesPerFace {
                        let byteOffset = (i * indicesPerFace + j) * MemoryLayout<UInt16>.size
                        let indexPointer = facesBuffer.advanced(by: byteOffset)
                        faceIndices.append(Int(indexPointer.assumingMemoryBound(to: UInt16.self).pointee))
                    }
                    parsedFaces.append(faceIndices)
                }
            } else {
                 print("⚠️ Unsupported face index format: bytesPerIndex = \(faces.bytesPerIndex)")
            }


            var vertexNormals = [SIMD3<Float>](repeating: .zero, count: localVertices.count)
            if !parsedFaces.isEmpty && !localVertices.isEmpty {
                for face in parsedFaces {
                    guard face.count == 3,
                          face[0] < localVertices.count, face[1] < localVertices.count, face[2] < localVertices.count else { continue }
                    let v0 = localVertices[face[0]]
                    let v1 = localVertices[face[1]]
                    let v2 = localVertices[face[2]]
                    let faceNormal = normalize(cross(v1 - v0, v2 - v0))
                    vertexNormals[face[0]] += faceNormal
                    vertexNormals[face[1]] += faceNormal
                    vertexNormals[face[2]] += faceNormal
                }
                for i in 0..<vertexNormals.count {
                    if length_squared(vertexNormals[i]) > .ulpOfOne {
                         vertexNormals[i] = normalize(vertexNormals[i])
                    }
                }
            } else {
                print("Warning: No faces or local vertices to compute normals for anchor \(anchor.identifier).")
            }

            for i in 0..<localVertices.count {
                let localVertex = localVertices[i]
                let localNormal = (i < vertexNormals.count && length_squared(vertexNormals[i]) > .ulpOfOne) ? vertexNormals[i] : nil

                let worldVertex4 = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
                let worldVertex = SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z) / worldVertex4.w

                var worldNormal: SIMD3<Float>? = nil
                if let ln = localNormal {
                     let rotationMatrix = simd_float3x3(columns: (transform.columns.0.xyz,
                                                                transform.columns.1.xyz,
                                                                transform.columns.2.xyz))
                    if length_squared(ln) > .ulpOfOne { // Ensure ln is not zero before normalizing
                        worldNormal = normalize(rotationMatrix * ln)
                    }
                }
                
                var sampledColor: SIMD3<UInt8>
                if let bestFrameForVertex = bestFrameForPoint(worldVertex, worldNormal: worldNormal) {
                    sampledColor = sampleColor(worldPoint: worldVertex, frame: bestFrameForVertex)
                } else {
                    sampledColor = SIMD3<UInt8>(128, 128, 128)
                    defaultColorCount += 1
                }
                verticesWithColor.append((position: worldVertex, color: sampledColor))
            }
        }
        arViewModel?.progressMessage = "Finalizing legacy export..."
        print("Processed \(totalVerticesProcessed) raw vertices across all anchors.")
        print("Vertices with default color: \(defaultColorCount) out of \(verticesWithColor.count)")
        
        guard !verticesWithColor.isEmpty else {
            print("❌ No vertices collected for PLY export.")
            arViewModel?.progressMessage = "Error: No vertices to export."
            return
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "ColoredPointCloud_\(timestamp).ply"
        
        var plyHeader = """
        ply
        format ascii 1.0
        element vertex \(verticesWithColor.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header
        """
        
        var plyBody = ""
        for vertexData in verticesWithColor {
            plyBody += "\n\(vertexData.position.x) \(vertexData.position.y) \(vertexData.position.z) \(vertexData.color.x) \(vertexData.color.y) \(vertexData.color.z)"
        }
        
        let fullPlyContent = plyHeader + plyBody
        
        do {
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsDirectory.appendingPathComponent(fileName)
            try fullPlyContent.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✅ Saved colored point cloud to \(fileURL.lastPathComponent) with \(verticesWithColor.count) points.")
            arViewModel?.progressMessage = "Exported to \(fileName)"
        } catch {
            print("❌ Error writing PLY file: \(error.localizedDescription)")
            arViewModel?.progressMessage = "Error: Could not save file."
        }
    }
}

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        return SIMD3<Scalar>(x, y, z)
    }
}

extension UInt8 {
    init(clamping value: Int) {
        if value < 0 {
            self = 0
        } else if value > UInt8.max {
            self = UInt8.max
        } else {
            self = UInt8(value)
        }
    }
}
