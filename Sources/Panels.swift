import UIKit
import SceneKit
import WebKit

enum Mode: String, CaseIterable { case vision = "ビジョン", tablet = "タブレット", none = "操作なし" }
enum Action: Equatable { case mode(Mode), open(String), pc, capture, walk }
protocol Closable: AnyObject { func close() }
protocol Scrollable: AnyObject { func scroll(_ dy: CGFloat) }

func drawText(_ s: String, in r: CGRect, size: CGFloat = 44) {
    let st = NSMutableParagraphStyle(); st.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: size),
                                            .foregroundColor: UIColor.white, .paragraphStyle: st]
    let h = (s as NSString).size(withAttributes: a).height
    (s as NSString).draw(in: CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h), withAttributes: a)
}

func makePlane(_ w: CGFloat, _ h: CGFloat) -> SCNPlane {
    let g = SCNPlane(width: w, height: h)
    let m = SCNMaterial(); m.lightingModel = .constant; m.isDoubleSided = false
    g.materials = [m]
    return g
}

/// ヒットテスト用: どのパネルか + 持ち主を持つ
final class Pane: SCNNode {
    let role: String
    weak var owner: AnyObject?
    init(role: String, plane: SCNPlane, owner: AnyObject?) {
        self.role = role; self.owner = owner
        super.init(); geometry = plane
    }
    required init?(coder: NSCoder) { fatalError() }
    var plane: SCNPlane { geometry as! SCNPlane }
    var image: Any? {
        get { plane.firstMaterial?.diffuse.contents }
        set { plane.firstMaterial?.diffuse.contents = newValue }
    }
}

final class HomePanel: SCNNode {
    static let apps: [(String, String)] = [
        ("Google", "https://www.google.com"), ("YouTube", "https://m.youtube.com"),
        ("Wikipedia", "https://ja.wikipedia.org"), ("GitHub", "https://github.com"),
        ("Yahoo!", "https://www.yahoo.co.jp"), ("PC画面", "pc://"), ("キャプチャ", "cap://"), ("通常モード", "walk://")]
    var pane: Pane!
    var mode: Mode = .vision { didSet { pane.image = draw() } }

    override init() {
        super.init()
        pane = Pane(role: "home", plane: makePlane(1.2, 0.72), owner: self)
        pane.image = draw()
        addChildNode(pane)
    }
    required init?(coder: NSCoder) { fatalError() }

    func action(at p: CGPoint) -> Action? {
        let x = p.x * 1200, y = p.y * 720
        if y < 150 { return .mode(Mode.allCases[min(2, max(0, Int(x / 400)))]) }
        guard y >= 170 else { return nil }
        let i = Int((y - 170) / 275) * 4 + Int(x / 300)
        guard i >= 0 && i < Self.apps.count else { return nil }
        switch Self.apps[i].1 { case "pc://": return .pc; case "cap://": return .capture; case "walk://": return .walk; default: return .open(Self.apps[i].1) }
    }

    private func draw() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 720)).image { _ in
            UIColor(white: 0.08, alpha: 0.92).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 1200, height: 720), cornerRadius: 48).fill()
            for (i, m) in Mode.allCases.enumerated() {
                let r = CGRect(x: CGFloat(i) * 400 + 20, y: 20, width: 360, height: 110)
                (m == mode ? UIColor.systemBlue : UIColor(white: 0.22, alpha: 1)).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 30).fill()
                drawText(m.rawValue, in: r)
            }
            for (i, a) in Self.apps.enumerated() {
                let r = CGRect(x: CGFloat(i % 4) * 300 + 15, y: 170 + CGFloat(i / 4) * 275, width: 270, height: 255)
                UIColor(white: 0.2, alpha: 1).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 36).fill()
                drawText(a.0, in: r)
            }
        }
    }
}

final class WebWindow: SCNNode, Closable, Scrollable {
    static let W: CGFloat = 1024, H: CGFloat = 640
    let web: WKWebView
    var webPane: Pane!, barPane: Pane!
    var timer: Timer?
    var busy = false, tick = 0
    var boostUntil: TimeInterval = 0
    var obs: [NSKeyValueObservation] = []
    var editingURL = false, urlText = "", shownTitle = ""

    init(url: String, host: UIView) {
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.W, height: Self.H))
        super.init()
        // alpha を下げるとスナップショットまで薄くなって真っ白に見えるので 1 のまま、手前の描画ビューで隠す
        host.addSubview(web)
        if let u = URL(string: url) { web.load(URLRequest(url: u)) }

        webPane = Pane(role: "web", plane: makePlane(0.96, 0.6), owner: self)
        barPane = Pane(role: "bar", plane: makePlane(0.96, 0.06), owner: self)
        barPane.position = SCNVector3(0, 0.33, 0)
        shownTitle = URL(string: url)?.host ?? url
        barPane.image = makeBar(shownTitle)
        addChildNode(webPane); addChildNode(barPane)

        // 変化があった時だけ高頻度でスナップショットを撮る(常時撮るとカクつく)
        obs.append(web.observe(\.estimatedProgress) { [weak self] _, _ in self?.boost(1.0) })
        obs.append(web.observe(\.title) { [weak self] _, _ in self?.boost(1.0) })
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.snap() }
        boost(3)
    }
    required init?(coder: NSCoder) { fatalError() }

    func boost(_ sec: Double) { boostUntil = max(boostUntil, CACurrentMediaTime() + sec) }

    func snap() {
        tick += 1
        let hot = CACurrentMediaTime() < boostUntil
        guard !busy, hot || tick % 10 == 0 else { return }
        busy = true
        let c = WKSnapshotConfiguration()
        c.snapshotWidth = NSNumber(value: Double(Self.W))
        c.afterScreenUpdates = false
        web.takeSnapshot(with: c) { [weak self] img, _ in
            guard let self = self else { return }
            self.busy = false
            if let img = img { self.webPane.image = img }
        }
    }

    func click(_ p: CGPoint) {
        let js = "var e=document.elementFromPoint(\(p.x * Self.W),\(p.y * Self.H));if(e){e.click();if(e.focus)e.focus();}"
        web.evaluateJavaScript(js)
        boost(1.0)
    }

    func scroll(_ dy: CGFloat) {
        let sv = web.scrollView
        let maxY = max(0, sv.contentSize.height - sv.bounds.height)
        sv.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, sv.contentOffset.y + dy))), animated: false)
        boost(0.5)
    }

    func close() {
        timer?.invalidate(); obs.removeAll(); web.removeFromSuperview(); removeFromParentNode()
    }
}

func makeBar(_ title: String) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 64)).image { _ in
        UIColor(white: 0.12, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1024, height: 64))
        drawText("⌂", in: CGRect(x: 0, y: 0, width: 120, height: 64), size: 36)
        drawText("⌨", in: CGRect(x: 120, y: 0, width: 120, height: 64), size: 36)
        drawText(title, in: CGRect(x: 240, y: 0, width: 664, height: 64), size: 28)
        drawText("✕", in: CGRect(x: 904, y: 0, width: 120, height: 64), size: 36)
    }
}

extension WebWindow: TextTarget {
    var targetName: String { editingURL ? "URL" : "ブラウザ" }
    var kbOffset: Float { -0.72 }

    func redrawBar() { barPane.image = makeBar(editingURL ? urlText + "▏" : shownTitle) }
    func beginURLEdit() { editingURL = true; urlText = ""; redrawBar() }

    func insert(_ s: String) {
        if editingURL { urlText += s; redrawBar() }
        else { web.evaluateJavaScript("document.execCommand('insertText',false,\(jsonString(s)))"); boost(0.8) }
    }
    func backspace() {
        if editingURL { if !urlText.isEmpty { urlText.removeLast() }; redrawBar() }
        else { web.evaluateJavaScript("document.execCommand('delete')"); boost(0.8) }
    }
    func enter() {
        if editingURL { loadText(urlText); editingURL = false; redrawBar(); return }
        web.evaluateJavaScript(Self.enterJS); boost(1.5)
    }
    func special(_ key: String, mods: [String]) {
        guard key == "esc" else { return }
        editingURL = false; redrawBar()
        web.evaluateJavaScript("document.activeElement&&document.activeElement.blur()")
    }

    func loadText(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var s = t
        if !t.hasPrefix("http://") && !t.hasPrefix("https://") {
            if t.contains(".") && !t.contains(" ") { s = "https://" + t }
            else { s = "https://www.google.com/search?q=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t) }
        }
        if let u = URL(string: s) { web.load(URLRequest(url: u)); shownTitle = u.host ?? s }
    }

    static let enterJS = """
    var e=document.activeElement;
    if(e){
      ['keydown','keypress','keyup'].forEach(function(t){e.dispatchEvent(new KeyboardEvent(t,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));});
      if(e.tagName==='TEXTAREA'){document.execCommand('insertText',false,'\\n');}
      else if(e.form){ if(e.form.requestSubmit){e.form.requestSubmit();}else{e.form.submit();} }
    }
    """
}
