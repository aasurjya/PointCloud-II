import SwiftUI
import SceneKit // For SCNScene, SCNView, etc.
import ModelIO // For MDLAsset if more advanced loading is needed later
import ARKit // For ARViewModel

struct OBJSceneView: View {
    @EnvironmentObject var arViewModel: ARViewModel // In case it's needed
    @Environment(\.presentationMode) var presentationMode

    let objURL: URL
    @State private var scene: SCNScene?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    ProgressView("Loading Model...")
                } else if let scene = scene {
                    CustomSceneView(scene: scene)
                        .edgesIgnoringSafeArea(.all)
                } else if let errorMessage = errorMessage {
                    Text("Error loading model: \(errorMessage)")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .onAppear(perform: loadScene)
            .navigationTitle(objURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func loadScene() {
        isLoading = true
        errorMessage = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Load the scene from the OBJ file URL
                // SCNSceneSource is good for inspecting contents first
                let sceneSource = SCNSceneSource(url: objURL, options: nil)
                let loadedScene = try sceneSource?.scene(options: [.convertToYUp: true, .flattenScene: true])
                
                guard let scene = loadedScene else {
                    throw NSError(domain: "OBJSceneView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to unwrap scene from SCNSceneSource."])
                }

                // Add a camera if there isn't one
                if scene.rootNode.camera == nil {
                    let cameraNode = SCNNode()
                    cameraNode.camera = SCNCamera()
                    cameraNode.position = SCNVector3(x: 0, y: 0, z: 3) // Adjust as needed
                    scene.rootNode.addChildNode(cameraNode)
                }

                // Add some basic lighting
                let ambientLightNode = SCNNode()
                ambientLightNode.light = SCNLight()
                ambientLightNode.light!.type = .ambient
                ambientLightNode.light!.color = UIColor(white: 0.6, alpha: 1.0)
                scene.rootNode.addChildNode(ambientLightNode)

                let omniLightNode = SCNNode()
                omniLightNode.light = SCNLight()
                omniLightNode.light!.type = .omni
                omniLightNode.light!.color = UIColor(white: 0.75, alpha: 1.0)
                omniLightNode.position = SCNVector3(x: 0, y: 50, z: 50)
                scene.rootNode.addChildNode(omniLightNode)
                
                // Ensure model is scaled and centered (optional, depends on OBJ export)
                // Sometimes models are too big or off-center
                // let (min, max) = scene.rootNode.boundingBox
                // let dx = min.x + 0.5 * (max.x - min.x)
                // let dy = min.y + 0.5 * (max.y - min.y)
                // let dz = min.z + 0.5 * (max.z - min.z)
                // scene.rootNode.pivot = SCNMatrix4MakeTranslation(dx, dy, dz)


                DispatchQueue.main.async {
                    self.scene = scene
                    self.isLoading = false
                }

            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    print("Error loading OBJ scene: \(error)")
                }
            }
        }
    }
}

// Custom SceneKit ViewRepresentable for more control
struct CustomSceneView: UIViewRepresentable {
    let scene: SCNScene
    
    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = scene
        scnView.allowsCameraControl = true // Enable user interaction with camera
        scnView.autoenablesDefaultLighting = false // We add our own lights
        scnView.backgroundColor = UIColor.systemBackground
        return scnView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
    }
}

struct OBJSceneView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a dummy OBJ file URL for previewing if possible,
        // otherwise, this might be hard to preview without a real file.
        // For now, let's assume a placeholder or handle potential nil.
        if let dummyURL = Bundle.main.url(forResource: "model", withExtension: "obj") { // Replace "model.obj" with an actual file in your bundle for preview
             OBJSceneView(objURL: dummyURL)
                .environmentObject(ARViewModel())
        } else {
            Text("Add a model.obj to your project bundle for preview, or provide a valid URL.")
        }
    }
}
