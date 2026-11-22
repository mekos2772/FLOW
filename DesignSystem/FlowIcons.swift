import SwiftUI

// MARK: - 设计说明
//
// FLOW 自定义图标集「Beadline」：2.6pt 圆头描边 + 标志性实心「音珠」。
//
// 为什么不用 SF Symbols：满屏 play.fill / magnifyingglass / star.fill 让界面看起来
// 和 Apple Music 没有任何区别。Beadline 的识别特征是**每个图标都有一颗实心圆点**——
// 播放键的起点、搜索手柄的末端、队列的行首、扬声器的出声点——同一个"音珠"语义
// 贯穿全套图标，离远看也知道这是 FLOW。
//
// 实现约定：
// - 每个 glyph 在 24×24 坐标系里作画（描边 + 实心音珠），由 `GlyphShape` 展开成墨迹轮廓、
//   统一比例缩放并按墨迹居中；颜色完全交给调用处的 `.foregroundStyle`，图标内部不出现任何 Color。
// - `FlowGlyph(sfSymbol:)` 是唯一的映射入口：组件只传原来的 SF 名字，
//   命中表就画自己的，没命中回落 `Image(systemName:)`（第三方语义不强行替换）。

// MARK: - 字形枚举

enum FlowGlyph: String, CaseIterable {
    // 播放控制
    case play, pause, backward, forward, shuffle, repeatAll, repeatOne, sequence
    // 音量
    case speaker, speakerMuted
    // 播放器部件
    case lyric, queue, search, clear, close, collapse, minimize, star, starFill
    case clock, home, playlist, note, refresh, remove, nowPlaying, calibrate
    // 状态/反馈
    case eyeSlash, warning
    // 设置侧栏与操作
    case settings, gear, paintpalette, textBubble, playCircle, keyboard
    case lock, lockOpen, lockShield, info, question
    // 文件/账户操作
    case trash, folder, docOnDoc, export, `import`, login, qrcode, restore, handRaised
    // 形态
    case expandHandle, moon, morphExpanded, morphCompact, morphCapsule, morphEdge, lines

    /// 该字形替换的 SF Symbol 名。
    var sfSymbol: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .backward: "backward.fill"
        case .forward: "forward.fill"
        case .shuffle: "shuffle"
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        case .sequence: "arrow.right.to.line"
        case .speaker: "speaker.wave.3"
        case .speakerMuted: "speaker.slash"
        case .lyric: "quote.bubble"
        case .queue: "list.bullet"
        case .search: "magnifyingglass"
        case .clear: "xmark.circle.fill"
        case .close: "xmark"
        case .collapse: "chevron.down"
        case .minimize: "minus"
        case .star: "star"
        case .starFill: "star.fill"
        case .clock: "clock"
        case .home: "house"
        case .playlist: "music.note.list"
        case .note: "music.note"
        case .refresh: "arrow.clockwise"
        case .remove: "minus.circle"
        case .nowPlaying: "waveform"
        case .calibrate: "arrow.left.and.right.square"
        case .eyeSlash: "eye.slash"
        case .warning: "exclamationmark.triangle.fill"
        case .settings: "slider.horizontal.3"
        case .gear: "gearshape"
        case .paintpalette: "paintpalette"
        case .textBubble: "text.bubble"
        case .playCircle: "play.circle"
        case .keyboard: "keyboard"
        case .lock: "lock.fill"
        case .lockOpen: "lock.open"
        case .lockShield: "lock.shield"
        case .info: "info.circle"
        case .question: "questionmark.circle"
        case .trash: "trash"
        case .folder: "folder"
        case .docOnDoc: "doc.on.doc"
        case .export: "square.and.arrow.up"
        case .import: "square.and.arrow.down"
        case .login: "rectangle.portrait.and.arrow.right"
        case .qrcode: "qrcode"
        case .restore: "arrow.counterclockwise"
        case .handRaised: "hand.raised"
        case .expandHandle: "arrow.up.left.and.arrow.down.right"
        case .moon: "moon"
        case .morphExpanded: "rectangle.inset.filled"
        case .morphCompact: "rectangle.compress.vertical"
        case .morphCapsule: "capsule"
        case .morphEdge: "rectangle.portrait.arrowtriangle.2.outward"
        case .lines: "line.3.horizontal"
        }
    }

    /// 用 SF Symbol 名解析自定义字形。没命中返回 nil——调用处回落 SF，
    /// 不认识的语义不强行套自己的形状。
    init?(sfSymbol name: String) {
        switch name {
        case "play.fill", "play": self = .play
        case "pause.fill", "pause": self = .pause
        case "backward.fill": self = .backward
        case "forward.fill": self = .forward
        case "shuffle": self = .shuffle
        case "repeat": self = .repeatAll
        case "repeat.1": self = .repeatOne
        case "arrow.right.to.line": self = .sequence
        case "speaker", "speaker.wave.1", "speaker.wave.2", "speaker.wave.3": self = .speaker
        case "speaker.slash", "speaker.slash.fill": self = .speakerMuted
        case "quote.bubble", "quote.bubble.fill": self = .lyric
        case "list.bullet": self = .queue
        case "magnifyingglass": self = .search
        case "xmark.circle.fill": self = .clear
        case "xmark": self = .close
        case "chevron.down": self = .collapse
        case "minus": self = .minimize
        case "star": self = .star
        case "star.fill": self = .starFill
        case "clock": self = .clock
        case "house", "house.fill": self = .home
        case "music.note.list": self = .playlist
        case "music.note": self = .note
        case "arrow.clockwise": self = .refresh
        case "minus.circle": self = .remove
        case "waveform": self = .nowPlaying
        case "arrow.left.and.right.square", "metronome": self = .calibrate
        case "slider.horizontal.3": self = .settings
        case "gearshape", "gearshape.fill": self = .gear
        case "paintpalette", "paintpalette.fill": self = .paintpalette
        case "text.bubble", "text.bubble.fill": self = .textBubble
        case "play.circle": self = .playCircle
        case "keyboard": self = .keyboard
        case "lock.fill", "lock": self = .lock
        case "lock.open", "lock.open.fill": self = .lockOpen
        case "lock.shield", "lock.shield.fill": self = .lockShield
        case "info.circle", "info.circle.fill": self = .info
        case "questionmark.circle", "questionmark.circle.fill": self = .question
        case "trash", "trash.fill": self = .trash
        case "folder", "folder.fill": self = .folder
        case "doc.on.doc", "doc.on.doc.fill": self = .docOnDoc
        case "square.and.arrow.up": self = .export
        case "square.and.arrow.down": self = .import
        case "rectangle.portrait.and.arrow.right", "rectangle.portrait.and.arrow.forward": self = .login
        case "qrcode": self = .qrcode
        case "arrow.counterclockwise": self = .restore
        case "hand.raised", "hand.raised.fill": self = .handRaised
        case "arrow.up.left.and.arrow.down.right": self = .expandHandle
        case "moon", "moon.fill": self = .moon
        case "rectangle.inset.filled": self = .morphExpanded
        case "rectangle.compress.vertical": self = .morphCompact
        case "capsule", "capsule.fill": self = .morphCapsule
        case "rectangle.portrait.arrowtriangle.2.outward": self = .morphEdge
        case "line.3.horizontal": self = .lines
        case "wrench.and.screwdriver", "wrench.and.screwdriver.fill": self = .gear
        case "exclamationmark.triangle", "exclamationmark.triangle.fill": self = .warning
        case "eye.slash", "eye.slash.fill": self = .eyeSlash
        default: return nil
        }
    }
}

// MARK: - 视图

/// `Image(systemName:) + .font(size:)` 的直接替代：画一枚 FLOW 图标。
struct FlowIconView: View {
    let glyph: FlowGlyph
    var size: CGFloat = 15

    var body: some View {
        glyph.shape
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 有自定义字形就画自己的，没有就回落 SF——业务代码只写原来的名字。
    @ViewBuilder
    func flowIcon(systemName: String, size: CGFloat, weight: Font.Weight = .medium) -> some View {
        if let glyph = FlowGlyph(sfSymbol: systemName) {
            FlowIconView(glyph: glyph, size: size)
        } else {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
        }
    }
}

// MARK: - 形状基础设施

/// 设计规格。所有字形共用一套比例——这是"一排图标看起来整齐"的前提。
private enum Spec {
    /// 24×24 画布里，墨迹（含描边外沿）最大占 18×18；这 18 个单位映射成 `size`。
    /// 描边中心线因此落在 4…20 之间。
    static let liveArea: CGFloat = 18
    /// 2/18：15pt 下约 1.7pt，和同字号正文笔画同重。
    static let stroke: CGFloat = 2
}

/// 一枚字形 = 描边部分 + 实心部分（音珠）− 镂空部分，都画在 24×24 设计坐标里。
///
/// 三条规则，各自修一种"歪"：
/// 1. **统一缩放**：`size / liveArea`，不按字形各自的外框放大——
///    否则宽扁字形和瘦高字形放大倍数不同，一排图标的笔画粗细、个头都对不上。
/// 2. **按真实墨迹居中**：先把描边展开成轮廓再取外框，圆头、粗笔画都算进去；
///    只看路径中心线的话，描边外沿会把字形往一侧"顶"出去。
/// 3. **描边并进轮廓**：返回的是可填充的墨迹轮廓，粗细随 `size` 等比，
///    不会溢出 frame，也不会在 11pt 下显得笨、在 32pt 下显得细。
private struct GlyphShape: Shape {
    var strokeWidth: CGFloat = Spec.stroke
    let stroke: @Sendable (inout Path) -> Void
    var fill: (@Sendable (inout Path) -> Void)?
    var cut: (@Sendable (inout Path) -> Void)?

    func path(in rect: CGRect) -> Path {
        var lines = Path()
        stroke(&lines)
        var ink = lines.isEmpty ? Path()
            : lines.strokedPath(StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
        if let fill {
            var solids = Path()
            fill(&solids)
            ink = ink.isEmpty ? solids : ink.union(solids)
        }
        if let cut {
            var hole = Path()
            cut(&hole)
            ink = ink.subtracting(hole.strokedPath(StrokeStyle(lineWidth: strokeWidth, lineCap: .round)))
        }
        let box = ink.cgPath.boundingBoxOfPath
        guard !box.isNull, !box.isEmpty else { return ink }
        let scale = min(rect.width, rect.height) / Spec.liveArea
        // CGAffineTransform 链式调用是"后写的先作用"：
        // 实际顺序 = 墨迹中心移到原点 → 缩放 → 移到 rect 中心。
        return ink.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY))
    }
}

private func glyph(width: CGFloat = Spec.stroke,
                   _ stroke: @escaping @Sendable (inout Path) -> Void,
                   fill: (@Sendable (inout Path) -> Void)? = nil,
                   cut: (@Sendable (inout Path) -> Void)? = nil) -> AnyShape {
    AnyShape(GlyphShape(strokeWidth: width, stroke: stroke, fill: fill, cut: cut))
}

/// 音珠：实心圆，不描边——描边会把小圆点糊成一个胖疙瘩。
private func bead(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, r: CGFloat = 1.7) {
    p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

private func line(_ p: inout Path, _ points: (CGFloat, CGFloat)...) {
    guard let first = points.first else { return }
    p.move(to: CGPoint(x: first.0, y: first.1))
    for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
}

private func polygon(_ p: inout Path, _ points: (CGFloat, CGFloat)...) {
    guard let first = points.first else { return }
    p.move(to: CGPoint(x: first.0, y: first.1))
    for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
    p.closeSubpath()
}

private func circle(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, r: CGFloat) {
    p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

private func roundRect(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 2) {
    p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
}

extension FlowGlyph {
    /// 形状本体：一律返回可填充的墨迹轮廓，颜色交给调用处。
    var shape: AnyShape {
        switch self {
        // ===== 播放控制 =====
        case .play:
            // 圆角三角，音珠在内部——"从这里开始播"的那颗点
            glyph({ p in polygon(&p, (8, 5.5), (19, 12), (8, 18.5)) },
                  fill: { p in bead(&p, 11.8, 12, r: 1.4) })
        case .pause:
            glyph(width: 3.6, { p in
                line(&p, (9, 6.5), (9, 17.5))
                line(&p, (15, 6.5), (15, 17.5))
            })
        case .backward:
            glyph({ p in
                polygon(&p, (17.5, 6), (10, 12), (17.5, 18))
                line(&p, (6.5, 6), (6.5, 18))
            }, fill: { p in bead(&p, 15, 12, r: 1.4) })
        case .forward:
            glyph({ p in
                polygon(&p, (6.5, 6), (14, 12), (6.5, 18))
                line(&p, (17.5, 6), (17.5, 18))
            }, fill: { p in bead(&p, 9, 12, r: 1.4) })
        case .shuffle:
            glyph { p in
                p.move(to: CGPoint(x: 4, y: 7))
                p.addCurve(to: CGPoint(x: 19.6, y: 17), control1: CGPoint(x: 11, y: 7), control2: CGPoint(x: 12, y: 17))
                p.move(to: CGPoint(x: 4, y: 17))
                p.addCurve(to: CGPoint(x: 19.6, y: 7), control1: CGPoint(x: 11, y: 17), control2: CGPoint(x: 12, y: 7))
                line(&p, (16.6, 4.4), (19.6, 7), (16.6, 9.6))
                line(&p, (16.6, 14.4), (19.6, 17), (16.6, 19.6))
            }
        case .repeatAll:
            glyph { p in
                // 顺时针绕一圈，止于正上方，箭头朝右
                p.addArc(center: CGPoint(x: 12, y: 12), radius: 6.8,
                         startAngle: .degrees(-30), endAngle: .degrees(270), clockwise: false)
                line(&p, (10, 3.2), (12, 5.2), (10, 7.2))
            }
        case .repeatOne:
            glyph { p in
                // 顺时针绕一圈，止于正上方，箭头朝右
                p.addArc(center: CGPoint(x: 12, y: 12), radius: 6.8,
                         startAngle: .degrees(-30), endAngle: .degrees(270), clockwise: false)
                line(&p, (10, 3.2), (12, 5.2), (10, 7.2))
                line(&p, (11, 10.6), (12.4, 9.8), (12.4, 15))
            }
        case .sequence:
            // 顺序播放：起点一颗珠，箭头抵到竖线
            glyph({ p in
                line(&p, (7, 12), (15.5, 12))
                line(&p, (12.2, 8.7), (15.5, 12), (12.2, 15.3))
                line(&p, (19.5, 6.5), (19.5, 17.5))
            }, fill: { p in bead(&p, 4.6, 12) })
        // ===== 音量 =====
        case .speaker:
            // 箱体 + 前锥，一道出声弧，弧外一颗音珠
            glyph({ p in
                polygon(&p, (4.5, 9.5), (7.6, 9.5), (12, 5.8), (12, 18.2), (7.6, 14.5), (4.5, 14.5))
                p.addArc(center: CGPoint(x: 12.4, y: 12), radius: 4.6,
                         startAngle: .degrees(-48), endAngle: .degrees(48), clockwise: false)
            }, fill: { p in bead(&p, 19.6, 12, r: 1.5) })
        case .speakerMuted:
            glyph { p in
                polygon(&p, (4.5, 9.5), (7.6, 9.5), (12, 5.8), (12, 18.2), (7.6, 14.5), (4.5, 14.5))
                line(&p, (15.6, 9.6), (20, 14.4))
                line(&p, (20, 9.6), (15.6, 14.4))
            }
        // ===== 播放器部件 =====
        case .lyric:
            // 气泡 + 尾巴，正中一颗音珠，两侧短线
            glyph({ p in
                roundRect(&p, 4, 4.5, 16, 11.5, r: 5.75)
                line(&p, (8.4, 15.8), (7.4, 19.2), (11.8, 16))
                line(&p, (7.4, 10.25), (9, 10.25))
                line(&p, (15, 10.25), (16.6, 10.25))
            }, fill: { p in bead(&p, 12, 10.25) })
        case .queue:
            glyph({ p in
                line(&p, (9.5, 7), (20, 7))
                line(&p, (9.5, 12), (20, 12))
                line(&p, (9.5, 17), (20, 17))
            }, fill: { p in
                bead(&p, 5.4, 7, r: 1.5); bead(&p, 5.4, 12, r: 1.5); bead(&p, 5.4, 17, r: 1.5)
            })
        case .search:
            glyph({ p in
                circle(&p, 10.5, 10.5, r: 6)
                line(&p, (15, 15), (17.6, 17.6))
            }, fill: { p in bead(&p, 18.6, 18.6, r: 1.8) })
        case .clear:
            glyph { p in
                circle(&p, 12, 12, r: 7.5)
                line(&p, (9.3, 9.3), (14.7, 14.7))
                line(&p, (14.7, 9.3), (9.3, 14.7))
            }
        case .close:
            glyph { p in
                line(&p, (6.5, 6.5), (17.5, 17.5))
                line(&p, (17.5, 6.5), (6.5, 17.5))
            }
        case .collapse:
            glyph { p in line(&p, (5.5, 9), (12, 15.5), (18.5, 9)) }
        case .minimize:
            // 「收进菜单栏」= 最小化：一根短横，和系统窗口的最小化语义一致。
            glyph { p in line(&p, (6, 12), (18, 12)) }
        case .star:
            glyph { p in Self.starPath(&p, center: CGPoint(x: 12, y: 12.6), outer: 8, inner: 3.6) }
        case .starFill:
            glyph({ _ in }, fill: { p in
                Self.starPath(&p, center: CGPoint(x: 12, y: 12.6), outer: 9, inner: 4.2)
            })
        case .clock:
            glyph { p in
                circle(&p, 12, 12, r: 7.5)
                line(&p, (12, 7.8), (12, 12), (15.2, 13.8))
            }
        case .home:
            // 无烟囱小屋 + 门口音珠
            glyph({ p in
                line(&p, (4, 11.2), (12, 4.5), (20, 11.2))
                line(&p, (6.4, 9.6), (6.4, 19), (17.6, 19), (17.6, 9.6))
            }, fill: { p in bead(&p, 12, 14.6) })
        case .playlist:
            // 三根长短谱线 + 一颗音符珠
            glyph({ p in
                line(&p, (4, 6.5), (20, 6.5))
                line(&p, (4, 11.5), (13, 11.5))
                line(&p, (4, 16.5), (10, 16.5))
                line(&p, (17.8, 17), (17.8, 10.2), (20, 11.4))
            }, fill: { p in p.addEllipse(in: CGRect(x: 14, y: 15, width: 4.6, height: 4)) })
        case .note:
            // 双八分音符：符头是两颗音珠
            glyph({ p in
                line(&p, (9.6, 17), (9.6, 6), (18.4, 4.5), (18.4, 15.4))
            }, fill: { p in
                p.addEllipse(in: CGRect(x: 4.6, y: 15.2, width: 5.6, height: 4.6))
                p.addEllipse(in: CGRect(x: 13.4, y: 13.6, width: 5.6, height: 4.6))
            })
        case .refresh:
            glyph { p in
                // 顺时针箭头止于右上
                p.addArc(center: CGPoint(x: 12, y: 12), radius: 6.8,
                         startAngle: .degrees(20), endAngle: .degrees(300), clockwise: false)
                line(&p, (12.5, 6.9), (15.4, 6.1), (14.6, 3.2))
            }
        case .remove:
            glyph { p in
                circle(&p, 12, 12, r: 7.5)
                line(&p, (8.6, 12), (15.4, 12))
            }
        case .nowPlaying:
            glyph(width: 2.6, { p in
                line(&p, (5.5, 9.5), (5.5, 14.5))
                line(&p, (9.8, 5.5), (9.8, 18.5))
                line(&p, (14.2, 7.5), (14.2, 16.5))
                line(&p, (18.5, 10), (18.5, 14))
            })
        case .calibrate:
            // 左右双向箭头，中点一颗音珠：歌词往前/往后挪
            glyph({ p in
                line(&p, (4, 12), (9.2, 12))
                line(&p, (14.8, 12), (20, 12))
                line(&p, (7, 9), (4, 12), (7, 15))
                line(&p, (17, 9), (20, 12), (17, 15))
            }, fill: { p in bead(&p, 12, 12, r: 1.9) })
        // ===== 状态/反馈 =====
        case .eyeSlash:
            glyph { p in
                p.move(to: CGPoint(x: 4, y: 12))
                p.addQuadCurve(to: CGPoint(x: 20, y: 12), control: CGPoint(x: 12, y: 4))
                p.addQuadCurve(to: CGPoint(x: 4, y: 12), control: CGPoint(x: 12, y: 20))
                line(&p, (6.5, 18.5), (17.5, 5.5))
            }
        case .warning:
            // 实心三角里镂出感叹号——只有三角的话读不出"警告"
            glyph(width: 2.2, { p in polygon(&p, (12, 5.2), (19.6, 18.4), (4.4, 18.4)) },
                  fill: { p in polygon(&p, (12, 5.2), (19.6, 18.4), (4.4, 18.4)) },
                  cut: { p in
                      line(&p, (12, 9.6), (12, 13.2))
                      line(&p, (12, 16.2), (12, 16.21))
                  })
        // ===== 设置侧栏 =====
        case .settings:
            // 三条滑轨 + 三颗实心滑块（滑块就是音珠）
            glyph({ p in
                line(&p, (4, 7), (20, 7))
                line(&p, (4, 12), (20, 12))
                line(&p, (4, 17), (20, 17))
            }, fill: { p in
                bead(&p, 14.5, 7, r: 2.4); bead(&p, 8.5, 12, r: 2.4); bead(&p, 15.5, 17, r: 2.4)
            })
        case .gear:
            // 真齿轮轮廓（齿顶平、齿根平），轴心是音珠——之前八根放射短线读成了星号
            glyph({ p in
                let outer: CGFloat = 7.8, inner: CGFloat = 5.6
                func pt(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
                    let a = deg * .pi / 180
                    return CGPoint(x: 12 + r * cos(a), y: 12 + r * sin(a))
                }
                for i in 0..<8 {
                    let a = CGFloat(i) * 45 - 90
                    let points = [pt(outer, a - 9), pt(outer, a + 9), pt(inner, a + 17), pt(inner, a + 28)]
                    if i == 0 { p.move(to: points[0]) } else { p.addLine(to: points[0]) }
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                p.closeSubpath()
            }, fill: { p in bead(&p, 12, 12, r: 2.2) })
        case .paintpalette:
            glyph({ p in
                p.move(to: CGPoint(x: 12, y: 4.5))
                p.addCurve(to: CGPoint(x: 19.5, y: 11), control1: CGPoint(x: 16.4, y: 4.5), control2: CGPoint(x: 19.5, y: 7.2))
                p.addCurve(to: CGPoint(x: 15, y: 14), control1: CGPoint(x: 19.5, y: 13.4), control2: CGPoint(x: 17.4, y: 14))
                p.addCurve(to: CGPoint(x: 13.6, y: 17.6), control1: CGPoint(x: 13, y: 14), control2: CGPoint(x: 12.4, y: 16.2))
                p.addCurve(to: CGPoint(x: 12, y: 19.5), control1: CGPoint(x: 14.6, y: 18.8), control2: CGPoint(x: 13.6, y: 19.5))
                p.addCurve(to: CGPoint(x: 4.5, y: 12), control1: CGPoint(x: 7.8, y: 19.5), control2: CGPoint(x: 4.5, y: 16.2))
                p.addCurve(to: CGPoint(x: 12, y: 4.5), control1: CGPoint(x: 4.5, y: 7.8), control2: CGPoint(x: 7.8, y: 4.5))
                p.closeSubpath()
            }, fill: { p in
                bead(&p, 8.4, 11, r: 1.4); bead(&p, 10.6, 7.8, r: 1.4); bead(&p, 14.6, 8.4, r: 1.4)
            })
        case .textBubble:
            glyph { p in
                roundRect(&p, 4, 4.5, 16, 11.5, r: 5.75)
                line(&p, (8.4, 15.8), (7.4, 19.2), (11.8, 16))
                line(&p, (8, 8.8), (16, 8.8))
                line(&p, (8, 11.8), (13, 11.8))
            }
        case .playCircle:
            glyph({ p in circle(&p, 12, 12, r: 7.8) },
                  fill: { p in polygon(&p, (10, 8.4), (16.2, 12), (10, 15.6)) })
        case .keyboard:
            glyph({ p in
                roundRect(&p, 4, 6.5, 16, 11)
                line(&p, (8, 14), (16, 14))
            }, fill: { p in
                bead(&p, 8, 10, r: 1.1); bead(&p, 12, 10, r: 1.1); bead(&p, 16, 10, r: 1.1)
            })
        case .lock, .lockShield:
            glyph({ p in
                roundRect(&p, 5.5, 10.5, 13, 9)
                p.move(to: CGPoint(x: 8.4, y: 10.5))
                p.addLine(to: CGPoint(x: 8.4, y: 8.2))
                p.addArc(center: CGPoint(x: 12, y: 8.2), radius: 3.6,
                         startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                p.addLine(to: CGPoint(x: 15.6, y: 10.5))
            }, fill: { p in bead(&p, 12, 15) })
        case .lockOpen:
            glyph({ p in
                roundRect(&p, 5.5, 10.5, 13, 9)
                p.move(to: CGPoint(x: 8.4, y: 10.5))
                p.addLine(to: CGPoint(x: 8.4, y: 8.2))
                p.addArc(center: CGPoint(x: 12, y: 8.2), radius: 3.6,
                         startAngle: .degrees(180), endAngle: .degrees(-20), clockwise: false)
            }, fill: { p in bead(&p, 12, 15) })
        case .info:
            glyph({ p in
                circle(&p, 12, 12, r: 7.5)
                line(&p, (12, 11), (12, 16))
            }, fill: { p in bead(&p, 12, 8, r: 1.3) })
        case .question:
            glyph({ p in
                circle(&p, 12, 12, r: 7.5)
                p.move(to: CGPoint(x: 9.6, y: 9.8))
                p.addCurve(to: CGPoint(x: 14.4, y: 9.8), control1: CGPoint(x: 9.6, y: 7.2), control2: CGPoint(x: 14.4, y: 7.2))
                p.addQuadCurve(to: CGPoint(x: 12, y: 13), control: CGPoint(x: 14.4, y: 11.6))
            }, fill: { p in bead(&p, 12, 16.2, r: 1.3) })
        // ===== 文件/账户 =====
        case .trash:
            glyph { p in
                line(&p, (5, 7), (19, 7))
                line(&p, (9.6, 7), (9.6, 4.8), (14.4, 4.8), (14.4, 7))
                line(&p, (6.8, 7), (7.6, 19.2), (16.4, 19.2), (17.2, 7))
                line(&p, (10.2, 10.6), (10.4, 15.8))
                line(&p, (13.8, 10.6), (13.6, 15.8))
            }
        case .folder:
            glyph { p in
                polygon(&p, (4, 6), (9.6, 6), (11.6, 8.4), (20, 8.4), (20, 18), (4, 18))
            }
        case .docOnDoc:
            glyph { p in
                roundRect(&p, 8, 4, 12, 13.5)
                line(&p, (4.5, 8), (4.5, 20), (14.5, 20))
            }
        case .export:
            glyph { p in
                line(&p, (8, 10.5), (5, 10.5), (5, 19.5), (19, 19.5), (19, 10.5), (16, 10.5))
                line(&p, (12, 14), (12, 4.5))
                line(&p, (8.8, 7.6), (12, 4.5), (15.2, 7.6))
            }
        case .import:
            glyph { p in
                line(&p, (8, 10.5), (5, 10.5), (5, 19.5), (19, 19.5), (19, 10.5), (16, 10.5))
                line(&p, (12, 4.5), (12, 14.5))
                line(&p, (8.8, 11.4), (12, 14.5), (15.2, 11.4))
            }
        case .login:
            glyph { p in
                line(&p, (12, 4.5), (6, 4.5), (6, 19.5), (12, 19.5))
                line(&p, (10, 12), (20, 12))
                line(&p, (16.8, 8.8), (20, 12), (16.8, 15.2))
            }
        case .qrcode:
            glyph({ p in
                roundRect(&p, 4.5, 4.5, 6, 6, r: 1)
                roundRect(&p, 13.5, 4.5, 6, 6, r: 1)
                roundRect(&p, 4.5, 13.5, 6, 6, r: 1)
            }, fill: { p in
                bead(&p, 14.4, 14.4, r: 1.2); bead(&p, 18.6, 14.4, r: 1.2)
                bead(&p, 14.4, 18.6, r: 1.2); bead(&p, 18.6, 18.6, r: 1.2)
            })
        case .restore:
            glyph { p in
                // refresh 的镜像：逆时针箭头止于左上
                p.addArc(center: CGPoint(x: 12, y: 12), radius: 6.8,
                         startAngle: .degrees(160), endAngle: .degrees(240), clockwise: true)
                line(&p, (11.5, 6.9), (8.6, 6.1), (9.4, 3.2))
            }
        case .handRaised:
            glyph { p in
                line(&p, (8, 19.5), (8, 12.5))
                p.addQuadCurve(to: CGPoint(x: 16, y: 12.5), control: CGPoint(x: 8, y: 9))
                p.addLine(to: CGPoint(x: 16, y: 19.5))
                line(&p, (9.8, 9.8), (9.8, 5))
                line(&p, (12.4, 9.4), (12.4, 4.6))
                line(&p, (15, 9.8), (15, 5.4))
            }
        // ===== 形态 =====
        case .expandHandle:
            glyph { p in
                line(&p, (10, 5), (5, 5), (5, 10))
                line(&p, (14, 19), (19, 19), (19, 14))
                line(&p, (5.4, 5.4), (10, 10))
                line(&p, (18.6, 18.6), (14, 14))
            }
        case .moon:
            glyph { p in
                // 新月 = 大圆减去偏移小圆，再描出轮廓
                let disk = Path(ellipseIn: CGRect(x: 4.5, y: 4.5, width: 15, height: 15))
                let bite = Path(ellipseIn: CGRect(x: 9.5, y: 2, width: 13, height: 13))
                p.addPath(disk.subtracting(bite))
            }
        case .morphExpanded:
            glyph({ p in
                roundRect(&p, 4, 5, 16, 14)
                line(&p, (9, 5), (9, 19))
            })
        case .morphCompact:
            glyph { p in
                roundRect(&p, 4.5, 8.5, 15, 7, r: 2.4)
                line(&p, (8, 4.5), (12, 6.4), (16, 4.5))
                line(&p, (8, 19.5), (12, 17.6), (16, 19.5))
            }
        case .morphCapsule:
            glyph({ p in roundRect(&p, 4, 8, 16, 8, r: 4) },
                  fill: { p in bead(&p, 12, 12, r: 1.6) })
        case .morphEdge:
            glyph { p in
                roundRect(&p, 4, 4.5, 9, 15)
                line(&p, (16, 12), (20, 12))
                line(&p, (17.8, 9.8), (20, 12), (17.8, 14.2))
            }
        case .lines:
            glyph { p in
                line(&p, (4.5, 7.5), (19.5, 7.5))
                line(&p, (4.5, 12), (19.5, 12))
                line(&p, (4.5, 16.5), (19.5, 16.5))
            }
        }
    }

    // MARK: 共用零件

    /// 五角星（外接半径/内凹半径可调；描边与填充共用同一几何）。
    private static func starPath(_ p: inout Path, center: CGPoint, outer: CGFloat, inner: CGFloat) {
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? outer : inner
            // -90° 起笔让顶点朝上
            let a = CGFloat(i) * .pi / 5 - .pi / 2
            let pt = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
    }
}

// MARK: - 品牌字标

/// FLOW 品牌图形：三条谱线，中间一条被声波穿过，末端一颗音珠。
///
/// 这是左上角的「文字商标位」——不是装饰图标，而是整个产品名字本身。
/// 谱线 = 歌词行，声波 = 正在流动的播放，音珠 = 声音落点（全套图标的签名元素）。
struct FlowMark: Shape {
    func path(in rect: CGRect) -> Path {
        // 设计画布 48×24
        var p = Path()
        p.move(to: CGPoint(x: 5, y: 6)); p.addLine(to: CGPoint(x: 23, y: 6))
        p.move(to: CGPoint(x: 5, y: 12))
        p.addCurve(to: CGPoint(x: 20, y: 12), control1: CGPoint(x: 10, y: 5.5), control2: CGPoint(x: 14, y: 18.5))
        p.addCurve(to: CGPoint(x: 33, y: 10), control1: CGPoint(x: 26, y: 12), control2: CGPoint(x: 28, y: 5.5))
        p.move(to: CGPoint(x: 5, y: 18)); p.addLine(to: CGPoint(x: 29, y: 18))
        // 音珠单独开子路径（它由 FlowMarkView 填充，不走描边）
        p.addEllipse(in: CGRect(x: 36.2, y: 8.1, width: 5.6, height: 5.6))
        let s = min(rect.width / 48, rect.height / 24)
        return p.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -24, y: -12))
    }

    /// 音珠部分（描边渲染时把珠扣掉，由 view 单独填实心）。
    fileprivate static func bead(in rect: CGRect) -> Path {
        let s = min(rect.width / 48, rect.height / 24)
        var p = Path()
        p.addEllipse(in: CGRect(x: 36.2, y: 8.1, width: 5.6, height: 5.6))
        return p.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -24, y: -12))
    }

    /// 谱线部分（不含珠）。
    fileprivate static func lines(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 5, y: 6)); p.addLine(to: CGPoint(x: 23, y: 6))
        p.move(to: CGPoint(x: 5, y: 12))
        p.addCurve(to: CGPoint(x: 20, y: 12), control1: CGPoint(x: 10, y: 5.5), control2: CGPoint(x: 14, y: 18.5))
        p.addCurve(to: CGPoint(x: 33, y: 10), control1: CGPoint(x: 26, y: 12), control2: CGPoint(x: 28, y: 5.5))
        p.move(to: CGPoint(x: 5, y: 18)); p.addLine(to: CGPoint(x: 29, y: 18))
        let s = min(rect.width / 48, rect.height / 24)
        return p.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -24, y: -12))
    }
}

/// 左上角字标：默认渲染成与文字等同的 primary 色。
struct FlowMarkView: View {
    var height: CGFloat = 15

    var body: some View {
        // 谱线描边 + 音珠实心，一个图形两种读法
        ZStack {
            BeadlessMark().stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
            BeadOnly().fill(Color.primary)
        }
        .frame(width: height * 2, height: height)
        .accessibilityLabel("FLOW")
    }

    private struct BeadlessMark: Shape {
        func path(in rect: CGRect) -> Path { FlowMark.lines(in: rect) }
    }
    private struct BeadOnly: Shape {
        func path(in rect: CGRect) -> Path { FlowMark.bead(in: rect) }
    }
}
