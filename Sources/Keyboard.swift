import UIKit
import SceneKit

/// キーボードの入力先(ブラウザ / URL欄 / PC)
protocol TextTarget: AnyObject {
    var targetName: String { get }
    var kbOffset: Float { get }          // ウィンドウの下にどれだけ離して置くか
    func insert(_ s: String)
    func backspace()
    func enter()
    func special(_ key: String, mods: [String])   // esc/tab/矢印/ショートカット
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) { self = matrix_identity_float4x4; columns.3 = SIMD4<Float>(t, 1) }
}

func jsonString(_ s: String) -> String {
    guard let d = try? JSONEncoder().encode(s), let r = String(data: d, encoding: .utf8) else { return "\"\"" }
    return r
}

// MARK: ローマ字 → ひらがな
enum Romaji {
    static let table: [String: String] = {
        var t = [String: String]()
        let v = ["a", "i", "u", "e", "o"]
        func row(_ c: String, _ ks: [String]) { for (i, k) in ks.enumerated() where !k.isEmpty { t[c + v[i]] = k } }
        row("", ["あ", "い", "う", "え", "お"]); row("k", ["か", "き", "く", "け", "こ"])
        row("s", ["さ", "し", "す", "せ", "そ"]); row("t", ["た", "ち", "つ", "て", "と"])
        row("n", ["な", "に", "ぬ", "ね", "の"]); row("h", ["は", "ひ", "ふ", "へ", "ほ"])
        row("m", ["ま", "み", "む", "め", "も"]); row("y", ["や", "", "ゆ", "", "よ"])
        row("r", ["ら", "り", "る", "れ", "ろ"]); row("w", ["わ", "うぃ", "う", "うぇ", "を"])
        row("g", ["が", "ぎ", "ぐ", "げ", "ご"]); row("z", ["ざ", "じ", "ず", "ぜ", "ぞ"])
        row("d", ["だ", "ぢ", "づ", "で", "ど"]); row("b", ["ば", "び", "ぶ", "べ", "ぼ"])
        row("p", ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"]); row("f", ["ふぁ", "ふぃ", "ふ", "ふぇ", "ふぉ"])
        row("v", ["ゔぁ", "ゔぃ", "ゔ", "ゔぇ", "ゔぉ"]); row("j", ["じゃ", "じ", "じゅ", "じぇ", "じょ"])
        row("l", ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]); row("x", ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"])
        let combos: [(String, String)] = [("ky", "き"), ("gy", "ぎ"), ("sy", "し"), ("sh", "し"), ("zy", "じ"), ("jy", "じ"),
                                          ("ty", "ち"), ("ch", "ち"), ("cy", "ち"), ("dy", "ぢ"), ("ny", "に"), ("hy", "ひ"),
                                          ("by", "び"), ("py", "ぴ"), ("my", "み"), ("ry", "り")]
        for (c, b) in combos { t[c + "a"] = b + "ゃ"; t[c + "u"] = b + "ゅ"; t[c + "o"] = b + "ょ"; t[c + "e"] = b + "ぇ" }
        t["shi"] = "し"; t["chi"] = "ち"; t["tsu"] = "つ"; t["fu"] = "ふ"
        t["xtu"] = "っ"; t["ltu"] = "っ"; t["xtsu"] = "っ"
        t["xya"] = "ゃ"; t["xyu"] = "ゅ"; t["xyo"] = "ょ"; t["lya"] = "ゃ"; t["lyu"] = "ゅ"; t["lyo"] = "ょ"
        t["thi"] = "てぃ"; t["dhi"] = "でぃ"; t["tsa"] = "つぁ"
        return t
    }()
    static let prefixes: Set<String> = {
        var s = Set<String>()
        for k in table.keys { for i in 1..<max(1, k.count) { s.insert(String(k.prefix(i))) } }
        return s
    }()
}

// MARK: 仮想キーボード(日本語入力つき)
final class KeyboardNode: SCNNode {
    struct Def { let label: String; let id: String; let span: Int }
    static func d(_ l: String, _ i: String, _ s: Int = 1) -> Def { Def(label: l, id: i, span: s) }
    static func chars(_ s: String) -> [Def] { s.map { d(String($0), String($0)) } }
    static let rows: [[Def]] = [
        chars("1234567890-") + [d("⌫", "bs")],
        chars("qwertyuiop[]"),
        chars("asdfghjkl;'") + [d("⏎", "enter")],
        [d("⇧", "shift", 2)] + chars("zxcvbnm,./"),
        [d("", "mode", 2), d("␣", "space", 4), d("Esc", "esc"), d("Tab", "tab"), d("←", "left"), d("↑", "up"), d("↓", "down"), d("→", "right")],
        [d("Ctrl", "ctrl", 2), d("Alt", "alt", 2), d("Win", "win", 2), d("Del", "del", 2), d("Home", "home", 2), d("End", "end", 2)]]
    static let shiftMap: [String: String] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*",
                                              "9": "(", "0": ")", "-": "_", "[": "{", "]": "}", ";": ":", "'": "\"",
                                              ",": "<", ".": ">", "/": "?"]
    static let kanaPunct: [String: String] = [",": "、", ".": "。", "-": "ー", "[": "「", "]": "」", "/": "・"]

    var pane: Pane!
    weak var target: TextTarget? { didSet { redraw() } }
    var kana = true, shift = false
    var mods = Set<String>()
    var pending = "", comp = ""
    var converting = false, seg = 0
    var segs: [(src: String, cands: [String])] = []
    var choice: [Int] = []

    override init() {
        super.init()
        pane = Pane(role: "kbd", plane: makePlane(1.2, 0.6), owner: self)
        addChildNode(pane)
        isHidden = true
        redraw()
    }
    required init?(coder: NSCoder) { fatalError() }

    var composing: Bool { !comp.isEmpty || !pending.isEmpty }
    var modList: [String] { var m = mods.sorted(); if shift { m.append("shift") }; return m }

    // MARK: タップ
    func tap(_ p: CGPoint) {
        let y = p.y * 600
        if y < 96 { barTap(p.x); return }
        let ri = min(5, max(0, Int((y - 96) / 84)))
        let col = p.x * 12
        var c: CGFloat = 0
        for k in Self.rows[ri] {
            if col >= c && col < c + CGFloat(k.span) { press(k.id); return }
            c += CGFloat(k.span)
        }
    }

    func barTap(_ x: CGFloat) {
        guard converting, x >= 0.3 else { return }
        let i = (choice[seg] / 5) * 5 + min(4, Int((x - 0.3) / 0.14))
        guard i < segs[seg].cands.count else { return }
        choice[seg] = i
        if seg < segs.count - 1 { seg += 1 }
        redraw()
    }

    // MARK: キー処理
    func press(_ id: String) {
        switch id {
        case "shift": shift.toggle()
        case "ctrl", "alt", "win": if mods.contains(id) { mods.remove(id) } else { mods.insert(id) }
        case "mode": commitAll(); kana.toggle()
        case "space": space()
        case "enter": enter()
        case "bs": backspace()
        case "left", "right", "up", "down": arrow(id)
        case "esc":
            if converting { cancelConversion() }
            else if composing { resetComposition() }
            else { target?.special("esc", mods: modList); clearMods() }
        case "tab", "del", "home", "end": commitAll(); target?.special(id, mods: modList); clearMods()
        default: character(id)
        }
        redraw()
    }

    func clearMods() { mods.removeAll(); shift = false }

    func character(_ id: String) {
        let isLetter = id.count == 1 && (id.first?.isLetter ?? false)
        if !mods.isEmpty { commitAll(); target?.special(id, mods: modList); clearMods(); return }
        let shifted = shift
        if kana {
            if converting { commitConversion() }
            if isLetter && !shifted { feed(Character(id)); return }
            if let k = Self.kanaPunct[id], !shifted { flushPending(); comp += k; return }
            commitAll()
            target?.insert(isLetter ? id.uppercased() : (shifted ? (Self.shiftMap[id] ?? id) : id))
        } else {
            target?.insert(shifted ? (isLetter ? id.uppercased() : (Self.shiftMap[id] ?? id)) : id)
        }
        shift = false
    }

    func feed(_ c: Character) {
        pending.append(c)
        while !pending.isEmpty {
            let p = pending
            if p.count >= 2 {
                let a = p.first!, b = p[p.index(after: p.startIndex)]
                if a == b, a.isLetter, !"aiueon".contains(a) { comp += "っ"; pending.removeFirst(); continue }
                if a == "n", b == "n" { comp += "ん"; pending.removeFirst(2); continue }
                if a == "n", !"aiueony".contains(b) { comp += "ん"; pending.removeFirst(); continue }
            }
            if let k = Romaji.table[p] { comp += k; pending = ""; continue }
            if Romaji.prefixes.contains(p) { break }
            comp += String(pending.removeFirst())
        }
    }

    func flushPending() { comp += (pending == "n" ? "ん" : pending); pending = "" }

    func space() {
        if converting { segs[seg].cands.isEmpty ? () : (choice[seg] = (choice[seg] + 1) % segs[seg].cands.count) }
        else if composing { flushPending(); startConversion() }
        else { target?.insert(" ") }
    }

    func enter() {
        if converting { commitConversion() }
        else if composing { flushPending(); target?.insert(comp); resetComposition() }
        else { target?.enter() }
    }

    func backspace() {
        if converting { cancelConversion() }
        else if !pending.isEmpty { pending.removeLast() }
        else if !comp.isEmpty { comp.removeLast() }
        else { target?.backspace() }
    }

    func arrow(_ id: String) {
        if converting {
            if id == "left" { seg = max(0, seg - 1) } else if id == "right" { seg = min(segs.count - 1, seg + 1) }
        } else if !composing { target?.special(id, mods: modList); clearMods() }
    }

    func commitAll() {
        if converting { commitConversion() }
        else if composing { flushPending(); target?.insert(comp); resetComposition() }
    }

    func commitConversion() {
        let text = zip(segs, choice).map { $0.0.cands[$0.1] }.joined()
        target?.insert(text)
        resetComposition()
    }

    func resetComposition() { comp = ""; pending = ""; cancelConversion() }
    func cancelConversion() { converting = false; segs = []; choice = []; seg = 0 }

    // MARK: かな漢字変換(Googleの変換API。ネットが無ければひらがな/カタカナのみ)
    static func katakana(_ s: String) -> String {
        String(s.unicodeScalars.map { (0x3041...0x3096).contains($0.value) ? Character(UnicodeScalar($0.value + 0x60)!) : Character($0) })
    }

    func startConversion() {
        let text = comp
        converting = true
        segs = [(text, [text, Self.katakana(text)])]; choice = [0]; seg = 0
        guard var c = URLComponents(string: "https://www.google.com/transliterate") else { return }
        c.queryItems = [URLQueryItem(name: "langpair", value: "ja-Hira|ja"), URLQueryItem(name: "text", value: text)]
        guard let url = c.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] d, _, _ in
            guard let d = d, let arr = try? JSONSerialization.jsonObject(with: d) as? [[Any]] else { return }
            var out: [(src: String, cands: [String])] = []
            for it in arr {
                guard it.count >= 2, let src = it[0] as? String, let cs = it[1] as? [String] else { continue }
                var l = cs
                for extra in [src, Self.katakana(src)] where !l.contains(extra) { l.append(extra) }
                out.append((src, l))
            }
            DispatchQueue.main.async {
                guard let self = self, self.converting, self.comp == text, !out.isEmpty else { return }
                self.segs = out; self.choice = Array(repeating: 0, count: out.count); self.seg = 0
                self.redraw()
            }
        }.resume()
    }

    // MARK: 描画
    func label(_ k: Def) -> String {
        if k.id == "mode" { return kana ? "あ" : "A" }
        if k.id.count == 1, let ch = k.id.first, ch.isLetter { return shift ? k.label.uppercased() : k.label }
        return k.label
    }

    func redraw() {
        pane.image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600)).image { _ in
            UIColor(white: 0.08, alpha: 0.94).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 1200, height: 600), cornerRadius: 30).fill()
            drawBar()
            for (ri, row) in Self.rows.enumerated() {
                var c = 0
                for k in row {
                    let r = CGRect(x: CGFloat(c) * 100 + 5, y: 96 + CGFloat(ri) * 84 + 5, width: CGFloat(k.span) * 100 - 10, height: 74)
                    let on = (k.id == "shift" && shift) || mods.contains(k.id)
                    (on ? UIColor.systemBlue : UIColor(white: 0.22, alpha: 1)).setFill()
                    UIBezierPath(roundedRect: r, cornerRadius: 14).fill()
                    drawText(label(k), in: r, size: 34)
                    c += k.span
                }
            }
        }
    }

    private func drawBar() {
        UIColor(white: 0.15, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: 5, y: 5, width: 1190, height: 86), cornerRadius: 14).fill()
        if converting {
            let shown = zip(segs, choice).map { $0.0.cands[$0.1] }.joined()
            drawText(shown, in: CGRect(x: 10, y: 5, width: 340, height: 86), size: 30)
            let base = (choice[seg] / 5) * 5
            for i in 0..<5 {
                let idx = base + i
                guard idx < segs[seg].cands.count else { break }
                let r = CGRect(x: 360 + CGFloat(i) * 168 + 4, y: 12, width: 160, height: 72)
                (idx == choice[seg] ? UIColor.systemBlue : UIColor(white: 0.28, alpha: 1)).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 12).fill()
                let t = segs[seg].cands[idx]
                drawText(t.count > 6 ? String(t.prefix(5)) + "…" : t, in: r, size: 30)
            }
        } else if composing {
            drawText(comp + pending, in: CGRect(x: 10, y: 5, width: 1180, height: 86), size: 40)
        } else {
            drawText("入力先: \(target?.targetName ?? "なし")", in: CGRect(x: 10, y: 5, width: 1180, height: 86), size: 30)
        }
    }
}
