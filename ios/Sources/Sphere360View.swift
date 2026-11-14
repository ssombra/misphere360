import SwiftUI
import SceneKit
import CoreMotion

/// Modos de proyección disponibles para el visor 360° de fotografías.
public enum PhotoProjectionMode: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case fisheye = "Fisheye"
    case littlePlanet = "Little Planet"
    case rabbitHole = "Rabbit Hole"
    case crystalBall = "Crystal Ball"
    case pano360 = "Pano 360"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .normal: return "viewfinder"
        case .fisheye: return "camera.aperture"
        case .littlePlanet: return "globe.americas.fill"
        case .rabbitHole: return "tornado"
        case .crystalBall: return "circle.inset.filled"
        case .pano360: return "pano.fill"
        }
    }
}

/// Visor 360° esférico interactivo nativo (SceneKit) a 60 FPS con control táctil, giroscopio y proyecciones
public struct Sphere360View: UIViewRepresentable {
    let image: UIImage
    var enableMotion: Bool = false
    var projectionMode: PhotoProjectionMode = .normal

    public func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 60

        let scene = SCNScene()
        scnView.scene = scene

        // Esfera 360°
        let sphere = SCNSphere(radius: 10.0)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.cullMode = .front
        material.isDoubleSided = false
        sphere.materials = [material]

        let sphereNode = SCNNode(geometry: sphere)
        // Invertir escala en X para que la orientación este/oeste coincida con la realidad desde dentro
        sphereNode.scale = SCNVector3(-1, 1, 1)
        scene.rootNode.addChildNode(sphereNode)

        // Cámara
        let camera = SCNCamera()
        camera.fieldOfView = 75.0
        camera.zNear = 0.1
        camera.zFar = 100.0

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        context.coordinator.sphereNode = sphereNode
        context.coordinator.sphereMaterial = material
        context.coordinator.cameraNode = cameraNode
        context.coordinator.camera = camera
        context.coordinator.scnView = scnView
        context.coordinator.applyProjectionMode(projectionMode, forceReset: true)

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
        if context.coordinator.currentMode != projectionMode {
            context.coordinator.applyProjectionMode(projectionMode, forceReset: true)
        }
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
        var sphereNode: SCNNode?
        var sphereMaterial: SCNMaterial?
        var cameraNode: SCNNode?
        var camera: SCNCamera?
        weak var scnView: SCNView?
        var currentMode: PhotoProjectionMode = .normal

        private var yaw: Float = 0.0
        private var pitch: Float = 0.0
        private var crystalDistance: Float = 24.0
        private let motionManager = CMMotionManager()

        func applyProjectionMode(_ mode: PhotoProjectionMode, forceReset: Bool) {
            currentMode = mode
            guard let camNode = cameraNode, let cam = camera, let sphereNode = sphereNode, let mat = sphereMaterial else { return }

            if forceReset {
                yaw = 0.0
                pitch = 0.0
            }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.25

            switch mode {
            case .normal:
                mat.cullMode = .front
                sphereNode.scale = SCNVector3(-1, 1, 1)
                sphereNode.eulerAngles = SCNVector3(0, 0, 0)
                camNode.position = SCNVector3(0, 0, 0)
                camNode.eulerAngles = SCNVector3(pitch, yaw, 0)
                cam.fieldOfView = 75.0

            case .fisheye:
                mat.cullMode = .front
                sphereNode.scale = SCNVector3(-1, 1, 1)
                sphereNode.eulerAngles = SCNVector3(0, 0, 0)
                camNode.position = SCNVector3(0, 0, 0)
                camNode.eulerAngles = SCNVector3(pitch, yaw, 0)
                cam.fieldOfView = 125.0

            case .littlePlanet:
                // Proyección estereográfica desde el polo norte mirando hacia el nadir (-Y)
                mat.cullMode = .front
                sphereNode.scale = SCNVector3(-1, 1, 1)
                sphereNode.eulerAngles = SCNVector3(0, yaw, 0)
                camNode.position = SCNVector3(0, 9.6, 0)
                camNode.eulerAngles = SCNVector3(-.pi / 2.0 + pitch * 0.35, 0, 0)
                cam.fieldOfView = 135.0

            case .rabbitHole:
                // Proyección estereográfica desde el polo sur mirando hacia el cenit (+Y)
                mat.cullMode = .front
                sphereNode.scale = SCNVector3(-1, 1, 1)
                sphereNode.eulerAngles = SCNVector3(0, yaw, 0)
                camNode.position = SCNVector3(0, -9.6, 0)
                camNode.eulerAngles = SCNVector3(.pi / 2.0 + pitch * 0.35, 0, 0)
                cam.fieldOfView = 135.0

            case .crystalBall:
                // Vista externa de la esfera completa (bola de cristal)
                mat.cullMode = .back
                sphereNode.scale = SCNVector3(1, 1, 1)
                sphereNode.eulerAngles = SCNVector3(pitch, yaw, 0)
                crystalDistance = 24.0
                camNode.position = SCNVector3(0, 0, crystalDistance)
                camNode.eulerAngles = SCNVector3(0, 0, 0)
                cam.fieldOfView = 60.0

            case .pano360:
                break
            }

            SCNTransaction.commit()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = scnView else { return }
            let translation = gesture.translation(in: view)
            let sensitivity: Float = 0.005

            switch currentMode {
            case .normal, .fisheye:
                yaw -= Float(translation.x) * sensitivity
                pitch -= Float(translation.y) * sensitivity
                pitch = max(-.pi / 2.2, min(.pi / 2.2, pitch))
                cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)

            case .littlePlanet:
                yaw += Float(translation.x) * sensitivity
                pitch += Float(translation.y) * sensitivity
                pitch = max(-1.0, min(1.0, pitch))
                sphereNode?.eulerAngles = SCNVector3(0, yaw, 0)
                cameraNode?.eulerAngles = SCNVector3(-.pi / 2.0 + pitch * 0.35, 0, 0)

            case .rabbitHole:
                yaw += Float(translation.x) * sensitivity
                pitch += Float(translation.y) * sensitivity
                pitch = max(-1.0, min(1.0, pitch))
                sphereNode?.eulerAngles = SCNVector3(0, yaw, 0)
                cameraNode?.eulerAngles = SCNVector3(.pi / 2.0 + pitch * 0.35, 0, 0)

            case .crystalBall:
                yaw += Float(translation.x) * sensitivity
                pitch += Float(translation.y) * sensitivity
                pitch = max(-.pi / 2.2, min(.pi / 2.2, pitch))
                sphereNode?.eulerAngles = SCNVector3(pitch, yaw, 0)

            case .pano360:
                break
            }

            gesture.setTranslation(.zero, in: view)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let cam = camera else { return }

            if currentMode == .crystalBall {
                var newDist = crystalDistance / Float(gesture.scale)
                newDist = max(13.0, min(38.0, newDist))
                crystalDistance = newDist
                cameraNode?.position = SCNVector3(0, 0, crystalDistance)
            } else {
                let maxFov: Double = (currentMode == .normal) ? 105.0 : 155.0
                let minFov: Double = (currentMode == .littlePlanet || currentMode == .rabbitHole) ? 80.0 : 35.0
                var newFov = Double(cam.fieldOfView) / Double(gesture.scale)
                newFov = max(minFov, min(maxFov, newFov))
                cam.fieldOfView = CGFloat(newFov)
            }

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
