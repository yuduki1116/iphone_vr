import MetalKit
import SceneKit
import ARKit

private let shaderSrc = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float4 xf; float2 t; float k1; float k2; float seg; float p0; float p1; float p2; };
vertex VOut vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
}
fragment float4 fs(VOut in [[stage_in]],
                   texture2d<float> sceneT [[texture(0)]],
                   texture2d<float> yT [[texture(1)]],
                   texture2d<float> cT [[texture(2)]],
                   texture2d<float> segT [[texture(3)]],
                   constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 c = in.uv * 2.0 - 1.0;
    float r2 = dot(c, c);
    float2 sc = c * (1.0 + u.k1 * r2 + u.k2 * r2 * r2);
    if (abs(sc.x) > 1.0 || abs(sc.y) > 1.0) return float4(0.0, 0.0, 0.0, 1.0);
    float2 uv = sc * 0.5 + 0.5;
    float4 sv = sceneT.sample(s, uv);
    float2 iuv = float2(u.xf.x * uv.x + u.xf.z * uv.y + u.t.x, u.xf.y * uv.x + u.xf.w * uv.y + u.t.y);
    float y = yT.sample(s, iuv).r;
    float2 cc = cT.sample(s, iuv).rg - 0.5;
    float3 rgb = float3(y + 1.402 * cc.y, y - 0.344136 * cc.x - 0.714136 * cc.y, y + 1.772 * cc.x);
    float3 base = sv.rgb + rgb * (1.0 - sv.a);
    float person = u.seg > 0.5 ? segT.sample(s, iuv).r : 0.0;
    return float4(mix(base, rgb, person), 1.0);
}
"""

struct EyeUniforms { var xf: SIMD4<Float>; var t: SIMD2<Float>; var k1: Float; var k2: Float; var seg: Float; var p0: Float; var p1: Float; var p2: Float }

/// パススルー(YCbCr→RGB) + SceneKit描画 を目ごとに合成し、レンズ歪み補正(樽型)をかけて出力
final class VRRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice, queue: MTLCommandQueue, pso: MTLRenderPipelineState
    let scn: SCNRenderer, eyes: [SCNNode]
    var cache: CVMetalTextureCache?
    var eyeTex = [MTLTexture?](repeating: nil, count: 2)
    var depthTex = [MTLTexture?](repeating: nil, count: 2)
    var frame: ARFrame?
    var seg: CVPixelBuffer?   // 人物(手)のマスク
    /// 歪み係数。ゴーグルに合わせて調整(大きいほど強く補正)
    var k1: Float = 0.18, k2: Float = 0.10

    init(view: MTKView, scene: SCNScene, eyes: [SCNNode]) {
        let dev = view.device!
        device = dev
        queue = dev.makeCommandQueue()!
        let lib = try! dev.makeLibrary(source: shaderSrc, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs")
        d.fragmentFunction = lib.makeFunction(name: "fs")
        d.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pso = try! dev.makeRenderPipelineState(descriptor: d)
        scn = SCNRenderer(device: dev, options: nil)
        scn.scene = scene
        self.eyes = eyes
        super.init()
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func ensure(_ w: Int, _ h: Int) {
        if let t = eyeTex[0], t.width == w, t.height == h { return }
        for i in 0..<2 {
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            c.usage = [.renderTarget, .shaderRead]; c.storageMode = .private
            eyeTex[i] = device.makeTexture(descriptor: c)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: w, height: h, mipmapped: false)
            d.usage = .renderTarget; d.storageMode = .private
            depthTex[i] = device.makeTexture(descriptor: d)
        }
    }

    private func plane(_ pb: CVPixelBuffer, _ i: Int, _ fmt: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
        guard let cache = cache else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt,
            CVPixelBufferGetWidthOfPlane(pb, i), CVPixelBufferGetHeightOfPlane(pb, i), i, &t)
        guard let ref = t, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return (ref, tex)
    }

    func draw(in view: MTKView) {
        guard let f = frame, let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor, let cb = queue.makeCommandBuffer() else { return }
        let W = Int(view.drawableSize.width) / 2, H = Int(view.drawableSize.height)
        guard W > 0, H > 0 else { return }
        ensure(W, H)
        let pb = f.capturedImage
        guard let y = plane(pb, 0, .r8Unorm), let c = plane(pb, 1, .rg8Unorm) else { return }

        let size = CGSize(width: W, height: H)
        let proj = f.camera.projectionMatrix(for: .landscapeRight, viewportSize: size, zNear: 0.05, zFar: 50)
        let inv = f.displayTransform(for: .landscapeRight, viewportSize: size).inverted()

        for i in 0..<2 {
            eyes[i].camera?.projectionTransform = SCNMatrix4(proj)
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = eyeTex[i]
            pd.colorAttachments[0].loadAction = .clear
            pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pd.colorAttachments[0].storeAction = .store
            pd.depthAttachment.texture = depthTex[i]
            pd.depthAttachment.loadAction = .clear; pd.depthAttachment.clearDepth = 1
            pd.depthAttachment.storeAction = .dontCare
            pd.stencilAttachment.texture = depthTex[i]
            pd.stencilAttachment.loadAction = .clear; pd.stencilAttachment.storeAction = .dontCare
            scn.pointOfView = eyes[i]
            scn.render(atTime: CACurrentMediaTime(), viewport: CGRect(x: 0, y: 0, width: W, height: H),
                       commandBuffer: cb, passDescriptor: pd)
        }

        var segTex: (CVMetalTexture, MTLTexture)?
        if let sp = seg { segTex = plane(sp, 0, .r8Unorm) }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pso)
        enc.setFragmentTexture(y.1, index: 1)
        enc.setFragmentTexture(c.1, index: 2)
        enc.setFragmentTexture(segTex?.1 ?? y.1, index: 3)
        var u = EyeUniforms(xf: SIMD4<Float>(Float(inv.a), Float(inv.b), Float(inv.c), Float(inv.d)),
                            t: SIMD2<Float>(Float(inv.tx), Float(inv.ty)), k1: k1, k2: k2,
                            seg: segTex != nil ? 1 : 0, p0: 0, p1: 0, p2: 0)
        for i in 0..<2 {
            enc.setViewport(MTLViewport(originX: Double(i * W), originY: 0, width: Double(W), height: Double(H), znear: 0, zfar: 1))
            enc.setFragmentTexture(eyeTex[i], index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<EyeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cb.addCompletedHandler { _ in withExtendedLifetime((y.0, c.0, segTex?.0)) {} }
        cb.present(drawable)
        cb.commit()
    }
}
