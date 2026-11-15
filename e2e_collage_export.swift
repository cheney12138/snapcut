// e2e_collage_export.swift —— 拼贴导出（CollageExporter）离线像素验证脚本
//
// 不启动 App、不发事件：纯离线合成 → 导出 → 逐像素断言。
//
// 覆盖面（对应 C1 约定的完整用户路径）：
//   1. 连续截图自动入画布：SnapGeometry.nextGridSlot → CollageDocument.adding
//   2. 拖动落位：SnapGeometry.snapTarget 拿 .gridSlot → doc.resizing
//      （先把第二片拖偏 6pt，验证吸附把它拉回 16pt gutter 格位）
//   3. 统一标注：一条 rect 描边（调色板蓝）画进上侧 padding 带（纯背景区，无遮挡）
//   4. 导出像素验证：两个色块位置 / 16pt 间隙即背景色 / 外圈 padding 背景 /
//      标注线存在 / 2x 缩放 / 分镜框描边压暗边缘 / 透明背景 alpha / 90° 旋转 AABB
//
// 用法：
//   swiftc -O -o /tmp/e2e_collage_export e2e_collage_export.swift \
//     Sources/Core/Domain/CollageDocument.swift Sources/Core/Domain/AnnotationModel.swift \
//     Sources/Core/Domain/RGBAColor.swift Sources/Core/Domain/SnapGeometry.swift \
//     Sources/UI/Annotate/CGRenderer.swift Sources/Core/Shared/Log.swift \
//     Sources/Adapters/Clipboard/ClipboardWriter.swift Sources/UI/Notification/CaptureToast.swift \
//     Sources/Adapters/Collage/CollageExporter.swift
//   /tmp/e2e_collage_export
//
// 产物：/tmp/e2e_collage_out_dark.png / _white2x.png / _alpha.png / _rot.png（人工目检）
// 铁律：不运行 App / 不 pkill / 不 commit。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 测试素材：纯色块位图

func solidImage(r: CGFloat, g: CGFloat, b: CGFloat, width: Int, height: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

// MARK: - 组装文档（严格走 C1 约定，不走 fields 直改）

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String) {
    let mark = cond ? "PASS" : "FAIL"
    print("[\(mark)] \(name) — \(detail)")
    if !cond { failures += 1 }
}

@main
enum E2ECollageExport {
    static func main() { run() }

    static func run() {
// 两片纯色块：红 200×120 @ (0,0)；蓝 160×140（下一格自动入画布）
var doc = CollageDocument()
let redID = UUID(), blueID = UUID()
doc = doc.adding(CollagePiece(id: redID, imageRef: "red", frame: CGRect(x: 0, y: 0, width: 200, height: 120)))

// 1. 连续截图自动入画布：nextGridSlot → adding
let slot2 = SnapGeometry.nextGridSlot(occupied: doc.pieces.map(\.frame), pieceSize: CGSize(width: 160, height: 140))
doc = doc.adding(CollagePiece(id: blueID, imageRef: "blue", frame: CGRect(origin: slot2, size: CGSize(width: 160, height: 140))))
check("nextGridSlot", slot2 == CGPoint(x: 216, y: 0),
      "slot2=\(slot2) 期望 (216,0)（红块右缘 200 + gutter 16）")

// 2. 拖动落位：拖向右下对角格位（唯一单邻居时双轴都命中的格位）——先拖偏 6pt，
//    snapTarget 应拉回完整 .gridSlot → doc.resizing 落位（docs/06 §2 吸附目标=格位）
let dragging = CGRect(origin: CGPoint(x: 210, y: 142), size: CGSize(width: 160, height: 140))
let snap = SnapGeometry.snapTarget(for: dragging, in: [doc.pieces[0].frame])
guard case .gridSlot(let slotRect) = snap else {
    print("FAIL: snapTarget 未命中 gridSlot，得到 \(snap)")
    exit(1)
}
doc = doc.resizing(pieceID: blueID, to: slotRect)
check("snapTarget→resizing", slotRect == CGRect(x: 216, y: 136, width: 160, height: 140),
      "落位 rect=\(slotRect)（拖偏 (210,142) 被吸附拉回 16pt gutter 格位）")

// 3. 自由拖回红块右侧（吸附是辅助不是强制，无吸附命中时停在松手位置）
doc = doc.moving(pieceID: blueID, to: CGPoint(x: 216, y: 0))
check("自由拖放", doc.piece(with: blueID)?.frame == CGRect(x: 216, y: 0, width: 160, height: 140),
      "蓝块最终 frame=\(doc.piece(with: blueID)!.frame) 期望 (216,0,160,140)")

// 3. 统一标注：蓝色 rect 描边（strokeWidth 4），顶边横穿 y=-20 的上侧 padding 带
//    （该带是纯背景区，无贴片遮挡——标注线像素可无歧义验证）
let ann = AnnotationModel(
    shape: .rect(CGRect(x: 60, y: -20, width: 120, height: 60)),
    colorIndex: 1, strokeWidth: 4
)
doc = CollageDocument(
    pieces: doc.pieces,
    annotations: [ann],
    canvasOrigin: doc.canvasOrigin,
    canvasSize: doc.canvasSize
)

let images: [String: CGImage] = [
    "red": solidImage(r: 1, g: 0, b: 0, width: 200, height: 120),
    "blue": solidImage(r: 0, g: 0, b: 1, width: 160, height: 140),
]
let provider: (String) -> CGImage? = { images[$0] }

// MARK: - 像素读取工具

// 统一归一化为「RGBA 8bpc、首行 = 图像顶行」的缓冲（RGB premultiplied）
func pixels(of image: CGImage) -> ([UInt8], Int, Int) {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    return (buf, w, h)
}

func px(_ buf: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
    let i = (y * w + x) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), Int(buf[i + 3]))
}

/// 画布坐标 → 像素坐标（导出 bounds 由 padding 外扩决定；缓冲首行 = 画布顶行）
func mapX(_ canvasX: CGFloat, minX: CGFloat, scale: CGFloat) -> Int { Int(((canvasX - minX) * scale).rounded()) }
func mapY(_ canvasY: CGFloat, minY: CGFloat, scale: CGFloat) -> Int { Int(((canvasY - minY) * scale).rounded()) }

func near(_ a: Int, _ b: Int, _ tol: Int) -> Bool { abs(a - b) <= tol }

// MARK: - 测试 A：1x 深色背景

var options = CollageExporter.ExportOptions(background: .dark, padding: 32, scale: 1)
guard let imgA = CollageExporter.export(document: doc, imageProvider: provider, options: options) else {
    print("FAIL: 导出返回 nil"); exit(1)
}
let (bufA, wA, hA) = pixels(of: imgA)
print("A: 尺寸 \(wA)×\(hA)")

// 内容 bbox = (0,0)-(376,140)，外扩 32 → 440×204
check("A 尺寸", wA == 440 && hA == 204, "\(wA)×\(hA) 期望 440×204（内容 376×140 + 2×32 padding）")

let dark = (30, 30, 34)  // #1E1E22
// 红块中心 画布 (100,60)；蓝块中心 画布 (296,70)
let redC = px(bufA, wA, mapX(100, minX: -32, scale: 1), mapY(60, minY: -32, scale: 1))
check("A 红块位置", near(redC.0, 255, 2) && redC.1 <= 2 && redC.2 <= 2, "px(132,92)=\(redC) 期望 (255,0,0)")
let blueC = px(bufA, wA, mapX(296, minX: -32, scale: 1), mapY(70, minY: -32, scale: 1))
check("A 蓝块位置", blueC.0 <= 2 && blueC.1 <= 2 && near(blueC.2, 255, 2), "px(328,102)=\(blueC) 期望 (0,0,255)")

// 间隙：画布 x=200..216（gutter 16pt），取中线 x=208, y=60
let gutter = px(bufA, wA, mapX(208, minX: -32, scale: 1), mapY(60, minY: -32, scale: 1))
check("A 间隙=背景色", near(gutter.0, dark.0, 3) && near(gutter.1, dark.1, 3) && near(gutter.2, dark.2, 3),
      "px(240,92)=\(gutter) 期望 #1E1E22 \(dark)")
// 外圈 padding：角 (2,2)
let corner = px(bufA, wA, 2, 2)
check("A padding=背景色", near(corner.0, dark.0, 3) && near(corner.1, dark.1, 3) && near(corner.2, dark.2, 3),
      "px(2,2)=\(corner) 期望 #1E1E22")
// 间隙逐列扫描：x 201..215 全是背景色（gutter 完整 15 列）
var gutterOK = true
for cx in 201...215 {
    let p = px(bufA, wA, mapX(CGFloat(cx), minX: -32, scale: 1), mapY(60, minY: -32, scale: 1))
    if !(near(p.0, dark.0, 3) && near(p.1, dark.1, 3) && near(p.2, dark.2, 3)) { gutterOK = false }
}
check("A 间隙逐列", gutterOK, "画布 x 201..215 @ y=60 全为 #1E1E22（16pt gutter 完整）")

// 标注线：调色板蓝 = RGBAColor.blue (0, 0.48, 1) → (0,122,255)
// 画布 (150,-20) 是描边顶边正中（padding 带，无遮挡）
let annPx = px(bufA, wA, mapX(150, minX: -32, scale: 1), mapY(-20, minY: -32, scale: 1))
check("A 标注线存在", annPx.0 <= 40 && (100...145).contains(annPx.1) && annPx.2 >= 230,
      "px(182,12)=\(annPx) 期望 ≈(0,122,255)")

// MARK: - 测试 B：2x 白色背景（分镜框描边验证）

options = CollageExporter.ExportOptions(background: .white, padding: 32, scale: 2)
guard let imgB = CollageExporter.export(document: doc, imageProvider: provider, options: options) else {
    print("FAIL: 导出返回 nil"); exit(1)
}
let (bufB, wB, hB) = pixels(of: imgB)
check("B 尺寸 2x", wB == 880 && hB == 408, "\(wB)×\(hB) 期望 880×408")
let gutterB = px(bufB, wB, mapX(208, minX: -32, scale: 2), mapY(60, minY: -32, scale: 2))
check("B 白背景间隙", gutterB.0 >= 250 && gutterB.1 >= 250 && gutterB.2 >= 250, "px=\(gutterB) 期望白")
// 分镜框：0.5pt 描边骑在画布 x=0 边缘，2x 下覆盖 px 63.5..64.5 → px64 半覆盖
// 边缘像素应比块内纯红暗（黑 0.4 alpha × ~0.5 覆盖 → r≈204）
let borderPx = px(bufB, wB, mapX(0, minX: -32, scale: 2), mapY(60, minY: -32, scale: 2))
let innerPx = px(bufB, wB, mapX(4, minX: -32, scale: 2), mapY(60, minY: -32, scale: 2))
check("B 分镜框描边", borderPx.0 < 245 && innerPx.0 >= 250,
      "边缘 px(64,184)=\(borderPx) 应压暗，块内 px(72,184)=\(innerPx) 应纯红")

// MARK: - 测试 C：透明背景（alpha 验证）

options = CollageExporter.ExportOptions(background: .transparent, padding: 32, scale: 1)
guard let imgC = CollageExporter.export(document: doc, imageProvider: provider, options: options) else {
    print("FAIL: 导出返回 nil"); exit(1)
}
let (bufC, wC, _) = pixels(of: imgC)
let alphaGutter = px(bufC, wC, mapX(208, minX: -32, scale: 1), mapY(60, minY: -32, scale: 1))
let alphaCorner = px(bufC, wC, 1, 1)
let alphaRed = px(bufC, wC, mapX(100, minX: -32, scale: 1), mapY(60, minY: -32, scale: 1))
check("C 透明背景 alpha", alphaGutter.3 == 0 && alphaCorner.3 == 0 && alphaRed.3 == 255,
      "间隙 alpha=\(alphaGutter.3) 角 alpha=\(alphaCorner.3)（期望 0），红块 alpha=\(alphaRed.3)（期望 255）")

// MARK: - 测试 D：90° 旋转（值语义：拷贝文档旋转，不动原 doc）

let rotDoc = doc.rotating(pieceID: blueID, to: 90)
options = CollageExporter.ExportOptions(background: .dark, padding: 32, scale: 1)
guard let imgD = CollageExporter.export(document: rotDoc, imageProvider: provider, options: options) else {
    print("FAIL: 导出返回 nil"); exit(1)
}
let (bufD, wD, hD) = pixels(of: imgD)
// 蓝块 160×140 转 90° → AABB (226,-10,140,160)；与红块 (0,0,200,120) 并集
// (0,-10)-(366,150)，外扩 32 → 430×224
check("D 旋转尺寸", wD == 430 && hD == 224, "\(wD)×\(hD) 期望 430×224（旋转 AABB 感知）")
let blueRot = px(bufD, wD, mapX(296, minX: -32, scale: 1), mapY(70, minY: -32, scale: 1))
check("D 旋转中心", blueRot.0 <= 2 && blueRot.1 <= 2 && near(blueRot.2, 255, 2),
      "px(328,112)=\(blueRot) 期望 (0,0,255)（绕中心旋转中心不变）")

// MARK: - 剪贴板链路（ClipboardWriter，CaptureToast 为纯 UI 不在离线范围）

let clipOK = MainActor.assumeIsolated {
    let written = ClipboardWriter.writeImage(imgA)
    let back = NSPasteboard.general.data(forType: .png)
    return written && back != nil
}
check("剪贴板链路", clipOK, "ClipboardWriter.writeImage → NSPasteboard PNG 读回非空")

// MARK: - 产物落盘（人工目检）

for (name, img) in [("dark", imgA), ("white2x", imgB), ("alpha", imgC), ("rot", imgD)] {
    let rep = NSBitmapImageRep(cgImage: img)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "/tmp/e2e_collage_out_\(name).png"))
    }
}

print(failures == 0 ? "== ALL PASS ==" : "== \(failures) FAILURE(S) ==")
exit(failures == 0 ? 0 : 1)
    }
}
