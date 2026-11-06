import SwiftUI
import SceneKit
import CoreMotion

/// Visor 360° esférico interactivo nativo (SceneKit) a 60 FPS con control táctil y giroscopio
public struct Sphere360View: UIViewRepresentable {
    let image: UIImage
    var enableMotion: Bool = false

    public func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 60

        let scene = SCNScene()
        scnView.scene = scene

        // Esfera 360° interior
        let sphere = SCNSphere(radius: 10.0)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.cullMode = .front
        material.isDoubleSided = true
        sphere.materials = [material]

        let sphereNode = SCNNode(geometry: sphere)
        // Invertir escala en X para que la orientación este/oeste coincida con la realidad
        sphereNode.scale = SCNVector3(-1, 1, 1)
        scene.rootNode.addChildNode(sphereNode)

        // Cámara en el centro exacto (0, 0, 0)
        let camera = SCNCamera()
        camera.fieldOfView = 75.0
        camera.zNear = 0.1
        camera.zFar = 100.0

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        context.coordinator.cameraNode = cameraNode
        context.coordinator.camera = camera
        context.coordinator.scnView = scnView

        // Gestos táctiles de arrastre (Pan) y zoom (Pinch)
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        scnView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        scnView.addGestureRecognizer(pinchGesture)

        if enableMotion {
            context.coordinator.startMotion()
        }

        return scnView
    }

    public func updateUIView(_ uiView: SCNView, context: Context) {
        if enableMotion {
            context.coordinator.startMotion()
        } else {
            context.coordinator.stopMotion()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator: NSObject {
        var cameraNode: SCNNode?
        var camera: SCNCamera?
        weak var scnView: SCNView?

        private var yaw: Float = 0.0
        private var pitch: Float = 0.0
        private let motionManager = CMMotionManager()

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = scnView else { return }
            let translation = gesture.translation(in: view)

            let sensitivity: Float = 0.005
            yaw -= Float(translation.x) * sensitivity
            pitch -= Float(translation.y) * sensitivity

            // Limitar inclinación vertical para evitar efecto gimble lock (-85° a +85°)
            pitch = max(-.pi / 2.2, min(.pi / 2.2, pitch))

            cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)
            gesture.setTranslation(.zero, in: view)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let cam = camera else { return }
            var newFov = Double(cam.fieldOfView) / Double(gesture.scale)
            newFov = max(35.0, min(105.0, newFov))
            cam.fieldOfView = CGFloat(newFov)
            gesture.scale = 1.0
        }

        func startMotion() {
            guard motionManager.isDeviceMotionAvailable else { return }
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
                guard let self = self, let motion = motion, let node = self.cameraNode else { return }
                let attitude = motion.attitude
                // Sincronizar rotación giroscópica con orientación del nodo de cámara
                node.eulerAngles = SCNVector3(
                    Float(-attitude.pitch),
                    Float(-attitude.yaw),
                    Float(-attitude.roll)
                )
            }
        }

        func stopMotion() {
            if motionManager.isDeviceMotionActive {
                motionManager.stopDeviceMotionUpdates()
            }
        }

        deinit {
            stopMotion()
        }
    }
}
