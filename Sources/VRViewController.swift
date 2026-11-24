import UIKit
import ARKit
import SceneKit
import MetalKit
import Vision

struct HandSample { var pinch: Bool; var midY: CGFloat; var tipUV: CGPoint }

final class VRViewController: UIViewController, ARSessionDelegate {
    enum RenderMode { case none, vr, walk }
    var renderMode: RenderMode = .none

    let session = ARSession()
    let scene = SCNScene()
    let head = SCNNode(), eyes = [SCNNode(), SCNNode()]
    let dots = [UIView(), UIView()]
    let webHost = UIView()
    var mtk: MTKView!
    var renderer: VRRenderer!
    let pcRx = PCReceiver()

    var home = HomePanel()
    let keyboard = KeyboardNode()
    var windows: [SCNNode] = []
    weak var activeNode: SCNNode?
    var mode: Mode = .vision { didSet { home.mode = mode } }

    // VR(手の認識)
    let visionQueue = DispatchQueue(label: "vision")
    var visionBusy = false, frameCount = 0
    var pinching = false, pinchMoved = false
    var pinchStartY: CGFloat = 0, pinchLastY: CGFloat = 0
    var scrollTarget: Scrollable?
    var pointerUV: CGPoint?, handSeen: TimeInterval = 0
    var dwellKey: String?, dwellStart: TimeInterval = 0, dwellFired = false

    // 通常モード(視点ドラッグ + ジョイスティック)
    let walkView = SCNView(), walkCam = SCNNode(), walkDot = UIView(), controls = WalkControls()
    let env = makeEnv()
    var yaw: Float = 0, pitch: Float = 0, walkPos = SIMD3<Float>(0, 1.6, 0)
    var joy = CGPoint.zero
    var link: CADisplayLink?
    var scrollTimer: Timer?
    var walkButtons: [UIButton] = []
    var bHome: UIButton!, bKb: UIButton!, bVR: UIButton!, bUp: UIButton!, bDown: UIButton!

    // 起動メニュー
    let menu = UIView(), menuTitle = UILabel()
    var menuVR: UIButton!, menuWalk: UIButton!

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }

    // MARK: 初期化
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // WebKitの実体は裏に置く(手前の描画ビューで隠れる。alpha は 1 のまま)
        webHost.frame = CGRect(x: 0, y: 0, width: WebWindow.W, height: WebWindow.H)
        view.addSubview(webHost)

        mtk = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.framebufferOnly = true
        mtk.preferredFramesPerSecond = 60
        mtk.isPaused = true; mtk.isHidden = true
        view.addSubview(mtk)

        walkView.scene = scene; walkView.pointOfView = walkCam
        walkView.rendersContinuously = true
        walkView.antialiasingMode = .multisampling4X
        walkView.isUserInteractionEnabled = false
        walkView.isHidden = true
        view.addSubview(walkView)

        controls.isHidden = true
        controls.onMove = { [weak self] x, y in self?.joy = CGPoint(x: x, y: y) }
        controls.onLook = { [weak self] dx, dy in
            guard let self = self else { return }
            self.yaw -= Float(dx) * 0.006
            self.pitch = max(-1.3, min(1.3, self.pitch - Float(dy) * 0.006))
        }
        controls.onTap = { [weak self] in self?.click() }
        view.addSubview(controls)

        bHome = pill("ホーム", #selector(tapHome)); bKb = pill("⌨", #selector(tapKb)); bVR = pill("VRへ", #selector(tapVR))
        bUp = pill("▲", nil); bDown = pill("▼", nil)
        bUp.tag = -1; bDown.tag = 1
        for b in [bUp!, bDown!] {
            b.addTarget(self, action: #selector(scrollStart(_:)), for: .touchDown)
            b.addTarget(self, action: #selector(scrollStop), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        walkButtons = [bHome, bKb, bVR, bUp, bDown]
        walkButtons.forEach { $0.isHidden = true }

        walkDot.backgroundColor = UIColor.white.withAlphaComponent(0.85)
        walkDot.layer.cornerRadius = 4; walkDot.isHidden = true
        view.addSubview(walkDot)

        scene.rootNode.addChildNode(head)
        home.isHidden = true
        scene.rootNode.addChildNode(home)
        scene.rootNode.addChildNode(keyboard)
        scene.rootNode.addChildNode(env)
        let cam = SCNCamera(); cam.fieldOfView = 75; cam.zNear = 0.05; cam.zFar = 100
        walkCam.camera = cam
        head.addChildNode(walkCam)
        for i in 0..<2 {
            eyes[i].camera = SCNCamera()
            eyes[i].position = SCNVector3(i == 0 ? -0.032 : 0.032, 0, 0)
            head.addChildNode(eyes[i])
            dots[i].backgroundColor = UIColor.white.withAlphaComponent(0.85)
            dots[i].layer.cornerRadius = 5
            dots[i].isHidden = true
            view.addSubview(dots[i])
        }
        renderer = VRRenderer(view: mtk, scene: scene, eyes: eyes)
        mtk.delegate = renderer
        session.delegate = self
        pcRx.start()
        buildMenu()
    }

    func pill(_ title: String, _ action: Selector?) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal); b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        b.layer.cornerRadius = 12; b.titleLabel?.font = .boldSystemFont(ofSize: 17)
        if let a = action { b.addTarget(self, action: a, for: .touchUpInside) }
        view.addSubview(b)
        return b
    }

    func buildMenu() {
        menu.backgroundColor = UIColor(white: 0.05, alpha: 1)
        menuTitle.text = "VR OS"; menuTitle.textColor = .white
        menuTitle.font = .boldSystemFont(ofSize: 44); menuTitle.textAlignment = .center
        menuVR = UIButton(type: .system); menuWalk = UIButton(type: .system)
        menuVR.setTitle("VRモード\n(ゴーグルで使う)", for: .normal)
        menuWalk.setTitle("通常モード\n(視点ドラッグ+ジョイスティック)", for: .normal)
        for b in [menuVR!, menuWalk!] {
            b.titleLabel?.numberOfLines = 2; b.titleLabel?.textAlignment = .center
            b.titleLabel?.font = .boldSystemFont(ofSize: 19)
            b.setTitleColor(.white, for: .normal)
            b.backgroundColor = UIColor.systemBlue; b.layer.cornerRadius = 20
            menu.addSubview(b)
        }
        menuVR.addTarget(self, action: #selector(tapVR), for: .touchUpInside)
        menuWalk.addTarget(self, action: #selector(tapWalk), for: .touchUpInside)
        menu.addSubview(menuTitle)
        view.addSubview(menu)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width, h = view.bounds.height, s = view.safeAreaInsets
        menu.frame = view.bounds
        menuTitle.frame = CGRect(x: 0, y: h * 0.16, width: w, height: 60)
        menuVR.frame = CGRect(x: w / 2 - 310, y: h * 0.42, width: 280, height: 100)
        menuWalk.frame = CGRect(x: w / 2 + 30, y: h * 0.42, width: 280, height: 100)
        mtk.frame = view.bounds; walkView.frame = view.bounds; controls.frame = view.bounds
        for i in 0..<2 {
            dots[i].frame = CGRect(x: CGFloat(i) * w / 2 + w / 4 - 5, y: h / 2 - 5, width: 10, height: 10)
        }
        walkDot.frame = CGRect(x: w / 2 - 4, y: h / 2 - 4, width: 8, height: 8)
        bHome.frame = CGRect(x: s.left + 16, y: 16, width: 90, height: 40)
        bKb.frame = CGRect(x: s.left + 114, y: 16, width: 56, height: 40)
        bVR.frame = CGRect(x: w - s.right - 106, y: 16, width: 90, height: 40)
        bUp.frame = CGRect(x: w - s.right - 70, y: h / 2 - 62, width: 54, height: 54)
        bDown.frame = CGRect(x: w - s.right - 70, y: h / 2 + 8, width: 54, height: 54)
    }

    // MARK: モード切替
    @objc func tapVR() { enterVR() }
    @objc func tapWalk() { enterWalk() }
    @objc func tapHome() { showHome() }
    @objc func tapKb() { toggleKeyboard(activeNode) }

    func enterVR() {
        renderMode = .vr
        menu.isHidden = true
        link?.invalidate(); link = nil
        walkView.isHidden = true; controls.isHidden = true; walkDot.isHidden = true
        walkButtons.forEach { $0.isHidden = true }
        env.isHidden = true
        scene.background.contents = UIColor.clear
        closeAllWindows()
        mtk.isHidden = false; mtk.isPaused = false
        dots.forEach { $0.isHidden = false }
        let cfg = ARWorldTrackingConfiguration()
        cfg.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation) {
            cfg.frameSemantics = .personSegmentation      // 手を仮想物より手前に出す
        }
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.renderMode == .vr { self?.showHome() }
        }
    }

    func enterWalk() {
        renderMode = .walk
        menu.isHidden = true
        session.pause()
        mtk.isHidden = true; mtk.isPaused = true
        dots.forEach { $0.isHidden = true }
        walkView.isHidden = false; controls.isHidden = false; walkDot.isHidden = false
        walkButtons.forEach { $0.isHidden = false }
        env.isHidden = false
        scene.background.contents = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1)
        closeAllWindows()
        walkPos = SIMD3<Float>(0, 1.6, 0); yaw = 0; pitch = 0; joy = .zero
        applyWalk()
        link?.invalidate()
        link = CADisplayLink(target: self, selector: #selector(walkTick(_:)))
        link?.add(to: .main, forMode: .common)
        showHome()
    }

    @objc func walkTick(_ l: CADisplayLink) {
        let dt = Float(l.targetTimestamp - l.timestamp)
        let fwd = SIMD3<Float>(-sin(yaw), 0, -cos(yaw)), right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        walkPos += (fwd * Float(joy.y) + right * Float(joy.x)) * 2.0 * dt
        applyWalk()
        updatePointer()
    }

    func applyWalk() {
        let q = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(walkPos, 1)
        head.simdTransform = m
    }

    @objc func scrollStart(_ b: UIButton) {
        scrollTimer?.invalidate()
        let dir = CGFloat(b.tag)
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            (self?.target()?.0.owner as? Scrollable)?.scroll(24 * dir)
        }
    }
    @objc func scrollStop() { scrollTimer?.invalidate(); scrollTimer = nil }

    func closeAllWindows() {
        for w in windows { (w as? Closable)?.close() }
        windows.removeAll()
        keyboard.isHidden = true; keyboard.target = nil
        activeNode = nil
    }

    // MARK: ARSession
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard renderMode == .vr else { return }
        head.simdTransform = frame.camera.transform
        if let sb = frame.segmentationBuffer { renderer.seg = sb }
        renderer.frame = frame
        frameCount += 1
        if frameCount % 5 == 0 { detectPinch(frame.capturedImage) }
        updateDwell()
        updatePointer()
    }

    // MARK: 狙い(手の指先 > 頭の向き)
    func handRay() -> (SIMD3<Float>, SIMD3<Float>)? {
        guard renderMode == .vr, CACurrentMediaTime() - handSeen < 0.3,
              let uv = pointerUV, let f = renderer.frame else { return nil }
        let size = CGSize(width: view.bounds.width / 2, height: view.bounds.height)
        let v = uv.applying(f.displayTransform(for: .landscapeRight, viewportSize: size))
        let proj = f.camera.projectionMatrix(for: .landscapeRight, viewportSize: size, zNear: 0.05, zFar: 50)
        let far = proj.inverse * SIMD4<Float>(Float(v.x) * 2 - 1, 1 - Float(v.y) * 2, 1, 1)
        let dirCam = simd_normalize(SIMD3<Float>(far.x, far.y, far.z) / far.w)
        let t = f.camera.transform
        let dir = simd_normalize(simd_make_float3(t * SIMD4<Float>(dirCam, 0)))
        return (simd_make_float3(t.columns.3), dir)
    }

    func target() -> (Pane, CGPoint)? {
        var from = simd_make_float3(head.simdTransform.columns.3)
        var dir = -simd_make_float3(head.simdTransform.columns.2)
        if let r = handRay() { from = r.0; dir = r.1 }
        let opts: [String: Any] = [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue]
        guard let r = scene.rootNode.hitTestWithSegment(from: SCNVector3(from), to: SCNVector3(from + dir * 6), options: opts).first,
              let pane = r.node as? Pane else { return nil }
        let g = pane.plane, l = r.localCoordinates
        let p = CGPoint(x: (CGFloat(l.x) + g.width / 2) / g.width, y: (g.height / 2 - CGFloat(l.y)) / g.height)
        return (pane, p)
    }

    func action(for pane: Pane, _ p: CGPoint) -> String? {
        switch pane.role {
        case "home": return home.action(at: p).map { "home\($0)" }
        case "bar":
            guard let o = pane.owner else { return nil }
            let id = ObjectIdentifier(o).hashValue
            return p.x > 0.883 ? "close\(id)" : (p.x < 0.117 ? "homebtn" : nil)
        default: return nil
        }
    }

    func updateDwell() {
        guard renderMode == .vr else { return }
        var key: String?
        if let (pane, p) = target() { key = action(for: pane, p) }
        let now = CACurrentMediaTime()
        if key != dwellKey { dwellKey = key; dwellStart = now; dwellFired = false }
        let need = handRay() != nil ? 0.8 : 1.2
        let on = key != nil && !dwellFired
        let prog = on ? min(1, (now - dwellStart) / need) : 0
        for d in dots { d.backgroundColor = prog > 0 ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.85) }
        if on && prog >= 1 { dwellFired = true; click() }
    }

    /// 狙いがPC画面の上にある間、PCのマウスカーソルを動かす
    func updatePointer() {
        guard mode != .none, let (pane, p) = target(), pane.role == "pc",
              let w = pane.owner as? PCWindow else { return }
        w.pointer(p)
    }

    // MARK: クリック
    func click() {
        guard let (pane, p) = target() else { return }
        switch pane.role {
        case "home":
            switch home.action(at: p) {
            case .mode(let m): mode = m
            case .open(let u): openWindow(u)
            case .pc: openPC()
            case .capture: openCapture()
            case .walk: enterWalk()
            case nil: break
            }
        case "bar": barClick(pane, p)
        case "web":
            guard let w = pane.owner as? WebWindow else { return }
            activeNode = w
            if w.editingURL { w.editingURL = false; w.redrawBar() }
            if mode != .none { w.click(p) }
        case "pc":
            guard let w = pane.owner as? PCWindow else { return }
            activeNode = w
            if mode != .none { w.pointer(p, force: true); w.click() }
        case "pctool":
            if mode != .none { (pane.owner as? PCWindow)?.tool(p) }
        case "kbd":
            if mode != .none { keyboard.tap(p) }
        default: break
        }
    }

    func barClick(_ pane: Pane, _ p: CGPoint) {
        let o = pane.owner
        if p.x > 0.883 {
            guard let c = o as? Closable else { return }
            if let t = o as? TextTarget, keyboard.target === t { keyboard.isHidden = true; keyboard.target = nil }
            c.close()
            windows.removeAll { $0 === o }
        } else if p.x < 0.117 {
            showHome()
        } else if p.x < 0.234 {
            toggleKeyboard(o as? SCNNode)
        } else if let w = o as? WebWindow, mode != .none {
            activeNode = w
            w.beginURLEdit()
            if keyboard.isHidden || keyboard.target !== w { keyboard.isHidden = true; toggleKeyboard(w) }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if renderMode == .vr { click() }     // ゴーグルのボタン/画面タップ用
    }

    // MARK: キーボード
    func toggleKeyboard(_ node: SCNNode?) {
        guard let n = node, let t = n as? TextTarget else { return }
        if !keyboard.isHidden, keyboard.target === t { keyboard.isHidden = true; return }
        keyboard.target = t
        keyboard.simdTransform = n.simdWorldTransform * simd_float4x4(translation: [0, t.kbOffset, 0.1])
        keyboard.isHidden = false
    }

    // MARK: 手の認識(Vision)
    func detectPinch(_ pb: CVPixelBuffer) {
        guard !visionBusy else { return }
        visionBusy = true
        visionQueue.async { [weak self] in
            let req = VNDetectHumanHandPoseRequest(); req.maximumHandCount = 1
            try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([req])
            var sample: HandSample?
            if let o = req.results?.first,
               let t = try? o.recognizedPoint(.thumbTip), let i = try? o.recognizedPoint(.indexTip),
               t.confidence > 0.4, i.confidence > 0.4 {
                let d = hypot(t.location.x - i.location.x, t.location.y - i.location.y)
                sample = HandSample(pinch: d < 0.05, midY: (t.location.y + i.location.y) / 2,
                                    tipUV: CGPoint(x: i.location.x, y: 1 - i.location.y))
            }
            DispatchQueue.main.async { self?.visionBusy = false; self?.handlePinch(sample) }
        }
    }

    func handlePinch(_ s: HandSample?) {
        guard let s = s else { if pinching { endPinch() }; return }
        handSeen = CACurrentMediaTime()
        if !s.pinch && !pinching { pointerUV = s.tipUV }       // つまんでいる間は指先位置を固定
        else if pointerUV == nil { pointerUV = s.tipUV }
        if s.pinch && !pinching {
            pinching = true; pinchMoved = false; pinchStartY = s.midY; pinchLastY = s.midY
            if let (tp, _) = target(), tp.role == "web" || tp.role == "pc" { scrollTarget = tp.owner as? Scrollable } else { scrollTarget = nil }
        } else if s.pinch && pinching {
            if abs(s.midY - pinchStartY) > 0.04 { pinchMoved = true }
            if pinchMoved && mode != .none { scrollTarget?.scroll((s.midY - pinchLastY) * 2400) }
            pinchLastY = s.midY
        } else if !s.pinch && pinching { endPinch() }
    }

    func endPinch() { pinching = false; if !pinchMoved { click() } }

    // MARK: ウィンドウ
    func showHome() {
        home.isHidden = false
        // VRでは「手より下、景色より上」: 近め(手が届く)・目線より少し下に置く
        placeFloating(home, distance: renderMode == .vr ? 0.8 : 1.1, down: renderMode == .vr ? 0.2 : 0)
    }

    func openWindow(_ url: String) { add(WebWindow(url: url, host: webHost), distance: 1.3) }
    func openPC() {
        let w = PCWindow(rx: pcRx)
        w.onKeyboard = { [weak self, weak w] in self?.toggleKeyboard(w) }
        add(w, distance: 1.5)
    }
    func openCapture() { add(CaptureWindow(), distance: 1.5) }

    func add(_ n: SCNNode, distance: Float) {
        scene.rootNode.addChildNode(n)
        windows.append(n)
        activeNode = n
        if mode == .tablet, renderMode == .vr, placeOnSurface(n) { return }
        placeFloating(n, distance: distance)
    }

    func placeFloating(_ n: SCNNode, distance: Float, down: Float = 0) {
        let t = head.simdTransform
        var f = -simd_make_float3(t.columns.2)
        f.y = 0
        f = simd_length(f) < 0.01 ? SIMD3<Float>(0, 0, -1) : simd_normalize(f)
        n.simdPosition = simd_make_float3(t.columns.3) + f * distance + SIMD3<Float>(0, -down, 0)
        let yaw = simd_quatf(angle: atan2(-f.x, -f.z), axis: [0, 1, 0])
        n.simdOrientation = down > 0 ? yaw * simd_quatf(angle: -0.3, axis: [1, 0, 0]) : yaw
    }

    /// タブレットモード(VR): 視線/指の先の床・机・壁に置く
    func placeOnSurface(_ n: SCNNode) -> Bool {
        guard let f = session.currentFrame,
              let hit = session.raycast(f.raycastQuery(from: CGPoint(x: 0.5, y: 0.5),
                                                       allowing: .estimatedPlane, alignment: .any)).first
        else { return false }
        let hp = simd_make_float3(hit.worldTransform.columns.3)
        var nrm = simd_normalize(simd_make_float3(hit.worldTransform.columns.1))
        let cam = simd_make_float3(f.camera.transform.columns.3)
        if simd_dot(nrm, cam - hp) < 0 { nrm = -nrm }
        if abs(nrm.y) > 0.8 {
            let d = cam - hp
            n.simdPosition = hp + [0, 0.15, 0]
            n.simdOrientation = simd_quatf(angle: atan2(d.x, d.z), axis: [0, 1, 0]) * simd_quatf(angle: -0.9, axis: [1, 0, 0])
        } else {
            n.simdPosition = hp + nrm * 0.01
            n.simdOrientation = simd_quatf(angle: atan2(nrm.x, nrm.z), axis: [0, 1, 0])
        }
        return true
    }
}
