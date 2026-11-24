import UIKit
import SceneKit
import AVFoundation
import CoreImage

/// UVCキャプチャボード(iOS 17以降の外部カメラ)の映像を表示
final class CaptureWindow: SCNNode, Closable, AVCaptureVideoDataOutputSampleBufferDelegate {
    var screen: Pane!, bar: Pane!
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "cap")
    let ci = CIContext()
    var timer: Timer?
    var started = false, sized = false
    var last: CFTimeInterval = 0

    override init() {
        super.init()
        screen = Pane(role: "cap", plane: makePlane(1.6, 0.9), owner: self)
        bar = Pane(role: "bar", plane: makePlane(1.6, 0.06), owner: self)
        bar.position = SCNVector3(0, 0.48, 0)
        bar.image = makeBar("キャプチャ")
        screen.image = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 720)).image { _ in
            UIColor(white: 0.1, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            drawText("キャプチャボードを接続してください", in: CGRect(x: 0, y: 310, width: 1280, height: 100), size: 52)
        }
        addChildNode(screen); addChildNode(bar)
        tryStart()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tryStart() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func tryStart() {
        guard !started else { return }
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let dev = ds.devices.first, let input = try? AVCaptureDeviceInput(device: dev) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        started = true
        DispatchQueue.global().async { [session] in session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - last > 1.0 / 30, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now
        let img = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }
        DispatchQueue.main.async { [weak self] in self?.show(cg) }
    }

    func show(_ cg: CGImage) {
        if !sized {
            sized = true
            let h = 1.6 * CGFloat(cg.height) / CGFloat(cg.width)
            screen.plane.height = h
            bar.position = SCNVector3(0, Float(h / 2 + 0.03), 0)
        }
        screen.image = cg
    }

    func close() {
        timer?.invalidate()
        DispatchQueue.global().async { [session] in session.stopRunning() }
        removeFromParentNode()
    }
}
