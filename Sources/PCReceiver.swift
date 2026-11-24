import UIKit
import SceneKit
import Network
import ImageIO

/// PCからのJPEGフレーム受信 ([4byte長さ BE][JPEG] の繰り返し) と、PCへの操作送信(1行1JSON)
final class PCReceiver {
    var listener: NWListener?
    var conn: NWConnection?
    var onFrame: ((CGImage) -> Void)?

    func start() {
        guard let l = try? NWListener(using: .tcp, on: 5555) else { return }
        l.newConnectionHandler = { [weak self] c in
            guard let self = self else { return }
            self.conn?.cancel(); self.conn = c
            c.start(queue: .global(qos: .userInitiated))
            self.readFrame(c)
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func send(_ s: String) {
        conn?.send(content: (s + "\n").data(using: .utf8), completion: .contentProcessed({ _ in }))
    }

    private func readFrame(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] d, _, _, err in
            guard let self = self, let d = d, d.count == 4, err == nil else { return }
            let b = Array(d)
            let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard n > 0, n < 20_000_000 else { c.cancel(); return }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, err in
                guard let body = body, body.count == n, err == nil else { return }
                let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                if let src = CGImageSourceCreateWithData(body as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, opts) { self.onFrame?(img) }
                self.readFrame(c)
            }
        }
    }
}

final class PCWindow: SCNNode, Closable, Scrollable, TextTarget {
    var screen: Pane!, bar: Pane!, tool: Pane!
    let rx: PCReceiver
    var onKeyboard: (() -> Void)?
    var rightNext = false, doubleNext = false, dragMode = false, dragging = false
    var sx: CGFloat = 0.5, sy: CGFloat = 0.5, lastSend: TimeInterval = 0

    var targetName: String { "PC" }
    var kbOffset: Float { -0.88 }

    init(rx: PCReceiver) {
        self.rx = rx
        super.init()
        screen = Pane(role: "pc", plane: makePlane(1.6, 0.9), owner: self)
        bar = Pane(role: "bar", plane: makePlane(1.6, 0.06), owner: self)
        bar.position = SCNVector3(0, 0.48, 0)
        bar.image = makeBar("PC画面")
        screen.image = PCWindow.waiting()
        tool = Pane(role: "pctool", plane: makePlane(1.6, 0.088), owner: self)
        tool.position = SCNVector3(0, -0.495, 0)
        for n in [screen!, bar!, tool!] { addChildNode(n) }
        redrawTool()
        rx.onFrame = { [weak self] img in DispatchQueue.main.async { self?.screen.image = img } }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func waiting() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 720)).image { _ in
            UIColor(white: 0.1, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            drawText("PCからの接続を待っています", in: CGRect(x: 0, y: 250, width: 1280, height: 100), size: 56)
            drawText("PCで pc_sender.exe を実行してください", in: CGRect(x: 0, y: 370, width: 1280, height: 100), size: 40)
        }
    }

    // MARK: マウス
    func pointer(_ p: CGPoint, force: Bool = false) {
        sx += (p.x - sx) * (force ? 1 : 0.35); sy += (p.y - sy) * (force ? 1 : 0.35)
        let now = CACurrentMediaTime()
        guard force || now - lastSend > 1.0 / 30 else { return }
        lastSend = now
        rx.send(String(format: "{\"t\":\"m\",\"x\":%.5f,\"y\":%.5f}", sx, sy))
    }

    func click() {
        let b = rightNext ? "right" : "left"
        if dragMode {
            let ev = dragging ? "u" : "d"
            rx.send("{\"t\":\"\(ev)\",\"b\":\"\(b)\"}")
            dragging.toggle()
        } else {
            rx.send("{\"t\":\"c\",\"b\":\"\(b)\",\"n\":\(doubleNext ? 2 : 1)}")
        }
        if rightNext || doubleNext { rightNext = false; doubleNext = false; redrawTool() }
    }

    func scroll(_ dy: CGFloat) { rx.send("{\"t\":\"s\",\"d\":\(Int(-dy * 3))}") }

    // MARK: ツールバー
    func tool(_ p: CGPoint) {
        switch Int(p.x * 4) {
        case 0: rightNext.toggle()
        case 1: doubleNext.toggle()
        case 2:
            dragMode.toggle()
            if !dragMode && dragging { rx.send("{\"t\":\"u\",\"b\":\"left\"}"); dragging = false }
        default: onKeyboard?()
        }
        redrawTool()
    }

    func redrawTool() {
        let labels = ["右クリック", "ダブル", "ドラッグ", "キーボード"]
        let on = [rightNext, doubleNext, dragMode, false]
        tool.image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 88)).image { _ in
            for i in 0..<4 {
                let r = CGRect(x: CGFloat(i) * 400 + 8, y: 8, width: 384, height: 72)
                (on[i] ? UIColor.systemBlue : UIColor(white: 0.2, alpha: 1)).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 24).fill()
                drawText(labels[i], in: r, size: 32)
            }
        }
    }

    // MARK: キーボード入力(TextTarget)
    func insert(_ s: String) { rx.send("{\"t\":\"text\",\"s\":\(jsonString(s))}") }
    func backspace() { sendKey("backspace", []) }
    func enter() { sendKey("enter", []) }
    func special(_ key: String, mods: [String]) { sendKey(key == "del" ? "delete" : key, mods) }
    func sendKey(_ k: String, _ mods: [String]) {
        rx.send("{\"t\":\"k\",\"k\":\(jsonString(k)),\"m\":[\(mods.map(jsonString).joined(separator: ","))]}")
    }

    func close() {
        if dragging { rx.send("{\"t\":\"u\",\"b\":\"left\"}") }
        rx.onFrame = nil; removeFromParentNode()
    }
}
