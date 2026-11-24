import AppKit
import SceneKit
import StarPulseCore
import SwiftUI

/// Native 3D sky in the manner of Dishylink's WebGL scene (src/components/satellite/skyScene.ts, MIT):
/// the dish's obstruction grid lifted onto a dome of points, the ground with a compass, the dish itself
/// pointing where it really points, and optionally the constellation overhead with the likely serving
/// satellite. SceneKit supplies the depth buffer, so a dot behind the dish is hidden and one in front shows.
/// Coordinates: y is up, x is east, -z is north; the dome radius is 1.
struct SkySceneView: NSViewRepresentable {
    enum Mode { case dome, sky }

    var mode: Mode
    var map: ObstructionMap?
    var boresightAzimuthDeg: Double
    var boresightElevationDeg: Double
    var satellites: [SatelliteSky] = []
    var serving: SatelliteSky?
    var rotating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class Coordinator {
        let scene = SCNScene()
        let world = SCNNode()
        let dome = SCNNode()
        let dish = SCNNode()
        let satellites = SCNNode()
        let serving = SCNNode()
        var lastMap: ObstructionMap?
        var lastBoresight: (Double, Double)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        let c = context.coordinator
        view.scene = c.scene
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.target = SCNVector3(0, 0.25, 0)
        view.defaultCameraController.minimumVerticalAngle = 5
        view.defaultCameraController.maximumVerticalAngle = 85

        c.scene.rootNode.addChildNode(c.world)
        [c.dome, c.dish, c.satellites, c.serving].forEach { c.world.addChildNode($0) }
        c.world.addChildNode(Self.ground())
        c.world.addChildNode(Self.compass())
        if mode == .sky { c.scene.rootNode.addChildNode(Self.stars()) }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = mode == .sky ? 48 : 38
        camera.camera?.zNear = 0.05
        let distance: Float = mode == .sky ? 4.2 : 3.3
        camera.position = SCNVector3(0, distance * 0.48, distance)
        camera.look(at: SCNVector3(0, 0.25, 0))
        c.scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 350
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-1.0, 0.6, 0)
        c.scene.rootNode.addChildNode(ambient); c.scene.rootNode.addChildNode(sun)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        if c.lastMap != map {
            c.lastMap = map
            c.dome.geometry = map.flatMap { Self.domePoints($0, boresightAzimuthDeg: boresightAzimuthDeg) }
        }
        if c.lastBoresight.map({ $0 != boresightAzimuthDeg || $1 != boresightElevationDeg }) ?? true {
            c.lastBoresight = (boresightAzimuthDeg, boresightElevationDeg)
            c.dish.childNodes.forEach { $0.removeFromParentNode() }
            c.dish.addChildNode(Self.miniDish(azimuthDeg: boresightAzimuthDeg, elevationDeg: boresightElevationDeg))
        }
        if mode == .sky {
            c.satellites.geometry = Self.satellitePoints(satellites)
            c.serving.childNodes.forEach { $0.removeFromParentNode() }
            if let serving { c.serving.addChildNode(Self.servingMarker(serving)) }
        }
        // One turn every two minutes, as in Dishylink; never when Reduce Motion is on.
        let shouldRotate = rotating && !reduceMotion
        if shouldRotate, c.world.action(forKey: "spin") == nil {
            c.world.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 120)), forKey: "spin")
        } else if !shouldRotate {
            c.world.removeAction(forKey: "spin")
        }
    }

    // MARK: Geometry

    private static func direction(azimuthDeg: Double, elevationDeg: Double) -> SIMD3<Float> {
        let a = azimuthDeg * .pi / 180, e = elevationDeg * .pi / 180
        return SIMD3(Float(sin(a) * cos(e)), Float(sin(e)), Float(-cos(a) * cos(e)))
    }

    private static func pointCloud(_ positions: [SIMD3<Float>], colors: [SIMD4<Float>], pointSize: CGFloat) -> SCNGeometry {
        let vertices = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                            componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let element = SCNGeometryElement(indices: (0..<Int32(positions.count)).map { $0 }, primitiveType: .point)
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = pointSize
        let geometry = SCNGeometry(sources: [vertices, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        geometry.materials = [material]
        return geometry
    }

    private static func rgba(_ hex: UInt32, _ alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(hex >> 16 & 0xff) / 255, Float(hex >> 8 & 0xff) / 255, Float(hex & 0xff) / 255, alpha)
    }

    /// Each grid cell becomes a dot on the hemisphere: distance from the grid centre is the zenith angle.
    static func domePoints(_ map: ObstructionMap, boresightAzimuthDeg: Double) -> SCNGeometry? {
        guard !map.isEmpty else { return nil }
        var positions: [SIMD3<Float>] = [], colors: [SIMD4<Float>] = []
        let maxTheta = Double(map.maxThetaDeg) * .pi / 180
        for row in 0..<map.rows { for col in 0..<map.cols {
            let (east, north) = map.eastNorth(row: row, col: col, boresightAzimuthDeg: boresightAzimuthDeg)
            let radial = hypot(east, north)
            guard radial <= 1 else { continue }
            let zenith = radial * maxTheta
            let x = radial > 0 ? east / radial * sin(zenith) : 0, z = radial > 0 ? -north / radial * sin(zenith) : 0
            positions.append(SIMD3(Float(x), Float(cos(zenith)), Float(z)))
            switch map.kind(row: row, col: col) {
            case .unmapped: colors.append(rgba(0x3a3a3a))      // context, not a reading: sinks back into the sky
            case .clear: colors.append(rgba(0xffffff))
            case .partial: colors.append(rgba(0x6e0f0f))
            case .obstructed: colors.append(rgba(0xf51e1e))
            }
        } }
        return pointCloud(positions, colors: colors, pointSize: 2.4)
    }

    /// A Starlink Mini drawn by StarPulse from its published size (298.5 x 259 x 38.5 mm): white face,
    /// grey side band, white back and a kickstand, with the face turned to the dish's real boresight.
    static func miniDish(azimuthDeg: Double, elevationDeg: Double) -> SCNNode {
        let k: CGFloat = 0.5 / 0.2985 // panel width = half the dome radius
        let width = 0.2985 * k, length = 0.259 * k, depth = 0.0385 * k, corner = 0.022 * k
        func material(_ white: CGFloat) -> SCNMaterial {
            let m = SCNMaterial(); m.diffuse.contents = NSColor(white: white, alpha: 1); m.lightingModel = .blinn
            m.specular.contents = NSColor(white: 0.25, alpha: 1); return m
        }
        let face = material(0.96), band = material(0.44), back = material(0.88)
        // Side band: the full body, rounded on its corners.
        let body = SCNBox(width: width, height: depth * 0.7, length: length, chamferRadius: corner)
        body.materials = [band]
        // Face and back caps sit just proud of the band so the grey shows only around the edge.
        let faceCap = SCNBox(width: width - 0.006, height: depth * 0.16, length: length - 0.006, chamferRadius: corner)
        faceCap.materials = [face]
        let backCap = SCNBox(width: width - 0.01, height: depth * 0.16, length: length - 0.01, chamferRadius: corner)
        backCap.materials = [back]
        let panel = SCNNode()
        panel.addChildNode(SCNNode(geometry: body))
        let faceNode = SCNNode(geometry: faceCap); faceNode.position = SCNVector3(0, depth * 0.4, 0); panel.addChildNode(faceNode)
        let backNode = SCNNode(geometry: backCap); backNode.position = SCNVector3(0, -depth * 0.4, 0); panel.addChildNode(backNode)
        // Kickstand: a flat leg hinged at the back, folded out toward the ground.
        let leg = SCNBox(width: width * 0.32, height: 0.006, length: length * 0.62, chamferRadius: 0.004)
        leg.materials = [band]
        let legNode = SCNNode(geometry: leg)
        legNode.pivot = SCNMatrix4MakeTranslation(0, 0, -length * 0.31) // hinge at one end
        legNode.position = SCNVector3(0, -depth * 0.55, -length * 0.1)
        legNode.eulerAngles = SCNVector3(CGFloat.pi / 3.2, 0, 0)
        panel.addChildNode(legNode)
        // Turn the face normal (+y) to the boresight.
        let target = direction(azimuthDeg: azimuthDeg, elevationDeg: elevationDeg)
        panel.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(target))
        panel.position = SCNVector3(0, 0.16, 0)
        let node = SCNNode()
        node.addChildNode(panel)
        return node
    }

    static func ground() -> SCNNode {
        let disc = SCNCylinder(radius: 1.45, height: 0.002)
        let material = SCNMaterial(); material.diffuse.contents = NSColor(white: 0.09, alpha: 1); material.lightingModel = .constant
        disc.materials = [material]
        let node = SCNNode(geometry: disc)
        node.position = SCNVector3(0, -0.002, 0)
        return node
    }

    static func compass() -> SCNNode {
        let node = SCNNode()
        let grey = SCNMaterial(); grey.diffuse.contents = NSColor(white: 0.55, alpha: 1); grey.lightingModel = .constant
        for (label, azimuth) in [("N", 0.0), ("E", 90), ("S", 180), ("W", 270)] {
            let text = SCNText(string: label, extrusionDepth: 0)
            text.font = NSFont(name: "D-DIN-Bold", size: 1) ?? .boldSystemFont(ofSize: 1)
            text.flatness = 0.05
            text.materials = [grey]
            let letter = SCNNode(geometry: text)
            let (min, max) = letter.boundingBox
            letter.pivot = SCNMatrix4MakeTranslation((max.x - min.x) / 2 + min.x, (max.y - min.y) / 2 + min.y, 0)
            letter.scale = SCNVector3(0.13, 0.13, 0.13)
            let d = direction(azimuthDeg: azimuth, elevationDeg: 0) * 1.22
            letter.position = SCNVector3(d.x, 0.002, d.z)
            letter.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0) // lie flat on the ground
            node.addChildNode(letter)
        }
        for tick in 0..<72 {
            let major = tick % 18 == 0
            let box = SCNBox(width: 0.006, height: 0.001, length: major ? 0.08 : 0.04, chamferRadius: 0)
            box.materials = [grey]
            let mark = SCNNode(geometry: box)
            let azimuth = Double(tick) * 5
            let d = direction(azimuthDeg: azimuth, elevationDeg: 0) * 1.08
            mark.position = SCNVector3(d.x, 0.001, d.z)
            mark.eulerAngles = SCNVector3(0, -CGFloat(azimuth * .pi / 180), 0)
            node.addChildNode(mark)
        }
        return node
    }

    /// Satellites ride a shell outside the dome, in their true directions.
    static func satellitePoints(_ satellites: [SatelliteSky]) -> SCNGeometry? {
        guard !satellites.isEmpty else { return nil }
        let positions = satellites.map { direction(azimuthDeg: $0.azimuthDeg, elevationDeg: $0.elevationDeg) * 1.75 }
        let colors = satellites.map { $0.elevationDeg >= ServingChooser.elevationFloorDeg ? rgba(0xffffff) : rgba(0x8a8a8a) }
        return pointCloud(positions, colors: colors, pointSize: 4)
    }

    static func servingMarker(_ serving: SatelliteSky) -> SCNNode {
        let gold = SCNMaterial(); gold.diffuse.contents = NSColor(red: 0.878, green: 0.643, blue: 0.133, alpha: 1); gold.lightingModel = .constant
        let tip = direction(azimuthDeg: serving.azimuthDeg, elevationDeg: serving.elevationDeg) * 1.75
        let sphere = SCNNode(geometry: SCNSphere(radius: 0.03)); sphere.geometry?.materials = [gold]
        sphere.simdPosition = tip
        let beamGeometry = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(0, 0.16, 0), SCNVector3(tip.x, tip.y, tip.z)])],
                                       elements: [SCNGeometryElement(indices: [Int32(0), 1], primitiveType: .line)])
        beamGeometry.materials = [gold]
        let node = SCNNode()
        node.addChildNode(SCNNode(geometry: beamGeometry)); node.addChildNode(sphere)
        return node
    }

    static func stars() -> SCNNode {
        var generator = SystemRandomNumberGenerator()
        let positions: [SIMD3<Float>] = (0..<700).map { _ in
            let u = Float.random(in: -1...1, using: &generator), t = Float.random(in: 0..<(2 * .pi), using: &generator)
            let r = (1 - u * u).squareRoot()
            return SIMD3(r * cos(t), abs(u) * 0.9 + 0.05, r * sin(t)) * 9
        }
        let colors = positions.map { _ in rgba(0xffffff, 1) * SIMD4(repeating: Float.random(in: 0.25...0.7)) }
        return SCNNode(geometry: pointCloud(positions, colors: colors, pointSize: 1.5))
    }
}
