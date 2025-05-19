import SwiftUI
import SceneKit

struct USDZViewer: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var arViewModel: ARViewModel // In case it's needed for other interactions

    let usdzURL: URL
    @State private var scene: SCNScene?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Model...")
                } else if let scene = scene {
                    SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                        .edgesIgnoringSafeArea(.all)
                } else if let errorMessage = errorMessage {
                    Text("Error loading model: \(errorMessage)")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .onAppear(perform: loadScene)
            .navigationTitle(usdzURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle()) // Ensures proper navigation behavior
    }

    private func loadScene() {
        isLoading = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // SCNScene can directly load USDZ files
                let loadedScene = try SCNScene(url: usdzURL, options: nil)
                
                // You might want to add default camera/lighting if the USDZ doesn't have them,
                // though .autoenablesDefaultLighting option in SceneView often handles this.
                // For explicit control:
                if loadedScene.rootNode.camera == nil {
                    let cameraNode = SCNNode()
                    cameraNode.camera = SCNCamera()
                    cameraNode.position = SCNVector3(x: 0, y: 0, z: 2) // Adjust position as needed
                    loadedScene.rootNode.addChildNode(cameraNode)
                }

                // if !loadedScene.rootNode.childNodes.contains(where: { $0.light != nil }) && !options.contains(.autoenablesDefaultLighting) {
                //    // Add a default light if autoenablesDefaultLighting is false and no lights exist
                //    let omniLightNode = SCNNode()
                //    omniLightNode.light = SCNLight()
                //    omniLightNode.light!.type = .omni
                //    omniLightNode.position = SCNVector3(x: 0, y: 10, z: 10)
                //    loadedScene.rootNode.addChildNode(omniLightNode)
                //
                //    let ambientLightNode = SCNNode()
                //    ambientLightNode.light = SCNLight()
                //    ambientLightNode.light!.type = .ambient
                //    ambientLightNode.light!.color = UIColor(white: 0.4, alpha: 1.0)
                //    loadedScene.rootNode.addChildNode(ambientLightNode)
                // }

                DispatchQueue.main.async {
                    self.scene = loadedScene
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    print("Error loading USDZ scene: \(error)")
                }
            }
        }
    }
}

struct USDZViewer_Previews: PreviewProvider {
    static var previews: some View {
        // To preview, add a dummy.usdz file to your project's bundle
        // and ensure it's included in the target.
        if let dummyURL = Bundle.main.url(forResource: "dummy", withExtension: "usdz") {
            USDZViewer(usdzURL: dummyURL)
                .environmentObject(ARViewModel()) // Provide a dummy ARViewModel if needed by the view
        } else {
            Text("Add a 'dummy.usdz' to your project bundle for preview, or provide a valid URL.")
        }
    }
}
