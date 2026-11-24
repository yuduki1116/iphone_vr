import UIKit
import SceneKit

/// 通常モードの操作: 左半分=ジョイスティック(触った場所が中心) / 右半分=ドラッグで視点、タップで決定
final class WalkControls: UIView {
    var onMove: ((CGFloat, CGFloat) -> Void)?    // 右+ / 前+  (-1...1)
    var onLook: ((CGFloat, CGFloat) -> Void)?    // 指の移動量(pt)
    var onTap: (() -> Void)?
    private var joyTouch: UITouch?, lookTouch: UITouch?
    private var joyOrigin = CGPoint.zero, lookLast = CGPoint.zero, lookStart = CGPoint.zero
    private var lookT: TimeInterval = 0, lookMoved = false
    private let base = UIView(), knob = UIView()
    private let radius: CGFloat = 60

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        base.frame = CGRect(x: 0, y: 0, width: 120, height: 120); base.layer.cornerRadius = 60
        base.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        base.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor; base.layer.borderWidth = 2
        knob.frame = CGRect(x: 0, y: 0, width: 56, height: 56); knob.layer.cornerRadius = 28
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        for v in [base, knob] { v.isUserInteractionEnabled = false; v.isHidden = true; addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if p.x < bounds.width * 0.5 {
                guard joyTouch == nil else { continue }
                joyTouch = t; joyOrigin = p
                base.center = p; knob.center = p; base.isHidden = false; knob.isHidden = false
            } else if lookTouch == nil {
                lookTouch = t; lookStart = p; lookLast = p; lookT = t.timestamp; lookMoved = false
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if t === joyTouch {
                var dx = p.x - joyOrigin.x, dy = p.y - joyOrigin.y
                let d = hypot(dx, dy)
                if d > radius { dx *= radius / d; dy *= radius / d }
                knob.center = CGPoint(x: joyOrigin.x + dx, y: joyOrigin.y + dy)
                onMove?(dx / radius, -dy / radius)
            } else if t === lookTouch {
                onLook?(p.x - lookLast.x, p.y - lookLast.y)
                lookLast = p
                if hypot(p.x - lookStart.x, p.y - lookStart.y) > 10 { lookMoved = true }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, tap: true) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, tap: false) }

    private func finish(_ touches: Set<UITouch>, tap: Bool) {
        for t in touches {
            if t === joyTouch {
                joyTouch = nil; base.isHidden = true; knob.isHidden = true; onMove?(0, 0)
            } else if t === lookTouch {
                if tap && !lookMoved && t.timestamp - lookT < 0.3 { onTap?() }
                lookTouch = nil
            }
        }
    }
}

/// 通常モードの床(2mごとのグリッド)
func makeEnv() -> SCNNode {
    let n = SCNNode()
    let img = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { _ in
        UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 128, height: 128))
        UIColor(white: 1, alpha: 0.28).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 128, height: 3))
        UIRectFill(CGRect(x: 0, y: 0, width: 3, height: 128))
    }
    let g = SCNPlane(width: 120, height: 120)
    let m = SCNMaterial(); m.lightingModel = .constant; m.isDoubleSided = true
    m.diffuse.contents = img
    m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
    m.diffuse.contentsTransform = SCNMatrix4MakeScale(60, 60, 1)
    g.materials = [m]
    let f = SCNNode(geometry: g)
    f.eulerAngles.x = -Float.pi / 2
    n.addChildNode(f)
    n.isHidden = true
    return n
}
