import UIKit

/// One glyph's geometry, in the 24 × 24 box Material icons are drawn on.
struct FlowIconDrawing {
    /// Paths drawn with the tint colour as a stroke.
    var strokes: [UIBezierPath] = []
    /// Paths filled with the tint colour.
    var fills: [UIBezierPath] = []
    /// Stroke width in the 24-point box.
    var strokeWidth: CGFloat = 2.0

    /// Renders the glyph into an image of `size` points, as a template so a tab bar or button can
    /// tint it.
    func image(size: CGFloat, color: UIColor = .black) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        UIGraphicsBeginImageContextWithOptions(canvas, false, 0.0)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else { return UIImage() }
        let scale = size / 24.0
        context.scaleBy(x: scale, y: scale)
        color.setStroke()
        color.setFill()
        for path in fills {
            path.fill()
        }
        for path in strokes {
            path.lineWidth = strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        let rendered = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        return rendered.withRenderingMode(.alwaysTemplate)
    }
}

/// Every icon the app draws. There are no SF Symbols here: each glyph is a bezier path so the app
/// looks the same on iOS 12 as it does on iOS 17.
enum FlowIcon: String, CaseIterable {
    case home
    case shorts
    case music
    case subscriptions
    case library
    case search
    case back
    case close
    case more
    case play
    case pause
    case next
    case previous
    case shuffle
    case repeatAll
    case repeatOne
    case volume
    case mute
    case fullscreen
    case pip
    case download
    case downloaded
    case heart
    case liked
    case playlist
    case add
    case check
    case share
    case settings
    case cast
    case subtitles
    case chapter
    case clock
    case trash
    case edit
    case drag
    case mic
    case equalizer
    case wifi
    case moon
    case sun
    case chevronDown
    case chevronRight
    case filter
    case sort
    case notes
    case recap
    case sync
    case importIcon
    case exportIcon
    case notification
    case verified
    case live
    case dislike
    case comment
    case queue

    /// The glyph's paths.
    var drawing: FlowIconDrawing {
        switch self {
        case .home:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(3, 10), FlowIcon.pt(12, 3), FlowIcon.pt(21, 10)]),
                FlowIcon.line([FlowIcon.pt(5.5, 9), FlowIcon.pt(5.5, 21), FlowIcon.pt(18.5, 21), FlowIcon.pt(18.5, 9)]),
                FlowIcon.line([FlowIcon.pt(10, 21), FlowIcon.pt(10, 14), FlowIcon.pt(14, 14), FlowIcon.pt(14, 21)]),
            ])

        case .shorts:
            let body = UIBezierPath(roundedRect: CGRect(x: 7, y: 2, width: 10, height: 20), cornerRadius: 4)
            let triangle = FlowIcon.triangle(center: FlowIcon.pt(12, 12), width: 4.5, height: 5.5)
            return FlowIconDrawing(strokes: [body], fills: [triangle])

        case .music:
            return FlowIconDrawing(strokes: [
                FlowIcon.circle(FlowIcon.pt(7.5, 18), 3.0),
                FlowIcon.circle(FlowIcon.pt(17.5, 16), 3.0),
                FlowIcon.line([FlowIcon.pt(10.5, 18), FlowIcon.pt(10.5, 7), FlowIcon.pt(20.5, 5), FlowIcon.pt(20.5, 16)]),
            ])

        case .subscriptions:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(3, 5), FlowIcon.pt(21, 5)]),
                FlowIcon.line([FlowIcon.pt(3, 10), FlowIcon.pt(21, 10)]),
                FlowIcon.line([FlowIcon.pt(3, 15), FlowIcon.pt(21, 15)]),
            ], fills: [
                FlowIcon.triangle(center: FlowIcon.pt(12, 19.5), width: 6, height: 5),
            ])

        case .library:
            let first = UIBezierPath(roundedRect: CGRect(x: 3, y: 4, width: 3, height: 16), cornerRadius: 1)
            let second = UIBezierPath(roundedRect: CGRect(x: 8.5, y: 4, width: 3, height: 16), cornerRadius: 1)
            let triangle = FlowIcon.triangle(center: FlowIcon.pt(17, 12), width: 5, height: 7)
            return FlowIconDrawing(strokes: [first, second], fills: [triangle])

        case .search:
            return FlowIconDrawing(strokes: [
                FlowIcon.circle(FlowIcon.pt(10.5, 10.5), 6.5),
                FlowIcon.line([FlowIcon.pt(15.5, 15.5), FlowIcon.pt(21, 21)]),
            ])

        case .back:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(20, 12), FlowIcon.pt(4, 12)]),
                FlowIcon.line([FlowIcon.pt(10, 6), FlowIcon.pt(4, 12), FlowIcon.pt(10, 18)]),
            ])

        case .close:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(6, 6), FlowIcon.pt(18, 18)]),
                FlowIcon.line([FlowIcon.pt(18, 6), FlowIcon.pt(6, 18)]),
            ])

        case .more:
            let top = FlowIcon.circle(FlowIcon.pt(12, 5), 1.6)
            let middle = FlowIcon.circle(FlowIcon.pt(12, 12), 1.6)
            let bottom = FlowIcon.circle(FlowIcon.pt(12, 19), 1.6)
            return FlowIconDrawing(fills: [top, middle, bottom])

        case .play:
            return FlowIconDrawing(fills: [
                FlowIcon.triangle(center: FlowIcon.pt(12.5, 12), width: 11, height: 14),
            ])

        case .pause:
            let left = UIBezierPath(roundedRect: CGRect(x: 6.5, y: 4, width: 4, height: 16), cornerRadius: 1.2)
            let right = UIBezierPath(roundedRect: CGRect(x: 13.5, y: 4, width: 4, height: 16), cornerRadius: 1.2)
            return FlowIconDrawing(fills: [left, right])

        case .next:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(18, 5), FlowIcon.pt(18, 19)]),
            ], fills: [
                FlowIcon.triangle(center: FlowIcon.pt(10, 12), width: 11, height: 14),
            ])

        case .previous:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(6, 5), FlowIcon.pt(6, 19)]),
            ], fills: [
                FlowIcon.triangleFlipped(center: FlowIcon.pt(14, 12), width: 11, height: 14),
            ])

        case .shuffle:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(3, 7), FlowIcon.pt(7, 7), FlowIcon.pt(17, 17), FlowIcon.pt(21, 17)]),
                FlowIcon.line([FlowIcon.pt(3, 17), FlowIcon.pt(7, 17), FlowIcon.pt(17, 7), FlowIcon.pt(21, 7)]),
                FlowIcon.line([FlowIcon.pt(18, 4), FlowIcon.pt(21, 7), FlowIcon.pt(18, 10)]),
                FlowIcon.line([FlowIcon.pt(18, 14), FlowIcon.pt(21, 17), FlowIcon.pt(18, 20)]),
            ])

        case .repeatAll:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(4, 9), FlowIcon.pt(4, 7), FlowIcon.pt(20, 7), FlowIcon.pt(20, 9)]),
                FlowIcon.line([FlowIcon.pt(20, 15), FlowIcon.pt(20, 17), FlowIcon.pt(4, 17), FlowIcon.pt(4, 15)]),
                FlowIcon.line([FlowIcon.pt(7, 4), FlowIcon.pt(4, 7), FlowIcon.pt(7, 10)]),
                FlowIcon.line([FlowIcon.pt(17, 14), FlowIcon.pt(20, 17), FlowIcon.pt(17, 20)]),
            ])

        case .repeatOne:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(4, 9), FlowIcon.pt(4, 7), FlowIcon.pt(20, 7), FlowIcon.pt(20, 9)]),
                FlowIcon.line([FlowIcon.pt(20, 15), FlowIcon.pt(20, 17), FlowIcon.pt(4, 17), FlowIcon.pt(4, 15)]),
                FlowIcon.line([FlowIcon.pt(7, 4), FlowIcon.pt(4, 7), FlowIcon.pt(7, 10)]),
                FlowIcon.line([FlowIcon.pt(17, 14), FlowIcon.pt(20, 17), FlowIcon.pt(17, 20)]),
                FlowIcon.line([FlowIcon.pt(12, 10.5), FlowIcon.pt(12, 14)]),
            ])

        case .volume:
            let cone = UIBezierPath()
            cone.move(to: FlowIcon.pt(3, 9))
            cone.addLine(to: FlowIcon.pt(7, 9))
            cone.addLine(to: FlowIcon.pt(12, 4))
            cone.addLine(to: FlowIcon.pt(12, 20))
            cone.addLine(to: FlowIcon.pt(7, 15))
            cone.addLine(to: FlowIcon.pt(3, 15))
            cone.close()
            return FlowIconDrawing(strokes: [
                cone,
                FlowIcon.arc(FlowIcon.pt(12, 12), 5.0, -55, 55),
                FlowIcon.arc(FlowIcon.pt(12, 12), 8.5, -50, 50),
            ])

        case .mute:
            let cone = UIBezierPath()
            cone.move(to: FlowIcon.pt(3, 9))
            cone.addLine(to: FlowIcon.pt(7, 9))
            cone.addLine(to: FlowIcon.pt(12, 4))
            cone.addLine(to: FlowIcon.pt(12, 20))
            cone.addLine(to: FlowIcon.pt(7, 15))
            cone.addLine(to: FlowIcon.pt(3, 15))
            cone.close()
            return FlowIconDrawing(strokes: [
                cone,
                FlowIcon.line([FlowIcon.pt(15, 9), FlowIcon.pt(21, 15)]),
                FlowIcon.line([FlowIcon.pt(21, 9), FlowIcon.pt(15, 15)]),
            ])

        case .fullscreen:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(3, 9), FlowIcon.pt(3, 3), FlowIcon.pt(9, 3)]),
                FlowIcon.line([FlowIcon.pt(15, 3), FlowIcon.pt(21, 3), FlowIcon.pt(21, 9)]),
                FlowIcon.line([FlowIcon.pt(21, 15), FlowIcon.pt(21, 21), FlowIcon.pt(15, 21)]),
                FlowIcon.line([FlowIcon.pt(9, 21), FlowIcon.pt(3, 21), FlowIcon.pt(3, 15)]),
            ])

        case .pip:
            return FlowIconDrawing(strokes: [
                UIBezierPath(roundedRect: CGRect(x: 2.5, y: 4.5, width: 19, height: 15), cornerRadius: 2),
                UIBezierPath(roundedRect: CGRect(x: 12, y: 11, width: 8, height: 7), cornerRadius: 1),
            ])

        case .download:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(12, 3), FlowIcon.pt(12, 15)]),
                FlowIcon.line([FlowIcon.pt(7, 10), FlowIcon.pt(12, 15), FlowIcon.pt(17, 10)]),
                FlowIcon.line([FlowIcon.pt(4, 20), FlowIcon.pt(20, 20)]),
            ])

        case .downloaded:
            return FlowIconDrawing(strokes: [
                FlowIcon.circle(FlowIcon.pt(12, 12), 9),
                FlowIcon.line([FlowIcon.pt(7.5, 12.5), FlowIcon.pt(10.5, 15.5), FlowIcon.pt(16.5, 8.5)]),
            ])

        case .heart:
            return FlowIconDrawing(strokes: [FlowIcon.heartPath()])

        case .liked:
            return FlowIconDrawing(fills: [FlowIcon.heartPath()])

        case .playlist:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(3, 6), FlowIcon.pt(15, 6)]),
                FlowIcon.line([FlowIcon.pt(3, 11), FlowIcon.pt(15, 11)]),
                FlowIcon.line([FlowIcon.pt(3, 16), FlowIcon.pt(10, 16)]),
            ], fills: [
                FlowIcon.triangle(center: FlowIcon.pt(17.5, 15), width: 7, height: 8),
            ])

        case .add:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(12, 4), FlowIcon.pt(12, 20)]),
                FlowIcon.line([FlowIcon.pt(4, 12), FlowIcon.pt(20, 12)]),
            ])

        case .check:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(4, 12.5), FlowIcon.pt(9.5, 18), FlowIcon.pt(20, 6)]),
            ])

        case .share:
            let top = FlowIcon.circle(FlowIcon.pt(18, 5), 2.6)
            let middle = FlowIcon.circle(FlowIcon.pt(6, 12), 2.6)
            let bottom = FlowIcon.circle(FlowIcon.pt(18, 19), 2.6)
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(8.3, 10.7), FlowIcon.pt(15.7, 6.3)]),
                FlowIcon.line([FlowIcon.pt(8.3, 13.3), FlowIcon.pt(15.7, 17.7)]),
                top,
                middle,
                bottom,
            ])

        case .settings:
            var paths: [UIBezierPath] = [FlowIcon.circle(FlowIcon.pt(12, 12), 3.2)]
            let teeth = 8
            for index in 0..<teeth {
                let angle = (CGFloat(index) / CGFloat(teeth)) * CGFloat.pi * 2.0
                let inner = FlowIcon.pt(12 + cos(angle) * 6.0, 12 + sin(angle) * 6.0)
                let outer = FlowIcon.pt(12 + cos(angle) * 9.0, 12 + sin(angle) * 9.0)
                paths.append(FlowIcon.line([inner, outer]))
            }
            return FlowIconDrawing(strokes: paths, strokeWidth: 1.8)

        case .cast:
            return FlowIconDrawing(strokes: [
                UIBezierPath(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 14), cornerRadius: 2),
                FlowIcon.arc(FlowIcon.pt(6, 16), 3.0, -90, 0),
                FlowIcon.arc(FlowIcon.pt(6, 16), 6.5, -90, 0),
                FlowIcon.arc(FlowIcon.pt(6, 16), 10.0, -90, 0),
            ])

        case .subtitles:
            return FlowIconDrawing(strokes: [
                UIBezierPath(roundedRect: CGRect(x: 2.5, y: 5, width: 19, height: 14), cornerRadius: 2),
                FlowIcon.line([FlowIcon.pt(6, 11), FlowIcon.pt(12, 11)]),
                FlowIcon.line([FlowIcon.pt(14.5, 11), FlowIcon.pt(18, 11)]),
                FlowIcon.line([FlowIcon.pt(6, 15), FlowIcon.pt(10, 15)]),
                FlowIcon.line([FlowIcon.pt(12.5, 15), FlowIcon.pt(18, 15)]),
            ])

        case .chapter:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(4, 5), FlowIcon.pt(4, 19)]),
                FlowIcon.line([FlowIcon.pt(8, 7), FlowIcon.pt(20, 7)]),
                FlowIcon.line([FlowIcon.pt(8, 12), FlowIcon.pt(20, 12)]),
                FlowIcon.line([FlowIcon.pt(8, 17), FlowIcon.pt(15, 17)]),
            ])

        case .clock:
            return FlowIconDrawing(strokes: [
                FlowIcon.circle(FlowIcon.pt(12, 12), 9),
                FlowIcon.line([FlowIcon.pt(12, 7), FlowIcon.pt(12, 12), FlowIcon.pt(16, 14)]),
            ])

        case .trash:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(4, 6.5), FlowIcon.pt(20, 6.5)]),
                FlowIcon.line([FlowIcon.pt(9, 6.5), FlowIcon.pt(9, 4), FlowIcon.pt(15, 4), FlowIcon.pt(15, 6.5)]),
                FlowIcon.line([FlowIcon.pt(6, 6.5), FlowIcon.pt(7, 20), FlowIcon.pt(17, 20), FlowIcon.pt(18, 6.5)]),
                FlowIcon.line([FlowIcon.pt(10, 10), FlowIcon.pt(10, 17)]),
                FlowIcon.line([FlowIcon.pt(14, 10), FlowIcon.pt(14, 17)]),
            ])

        case .edit:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(4, 20), FlowIcon.pt(4.8, 15.5), FlowIcon.pt(15.5, 4.8), FlowIcon.pt(19.2, 8.5), FlowIcon.pt(8.5, 19.2), FlowIcon.pt(4, 20)]),
                FlowIcon.line([FlowIcon.pt(13, 7.3), FlowIcon.pt(16.7, 11)]),
            ])

        case .drag:
            var dots: [UIBezierPath] = []
            for row in 0..<3 {
                for column in 0..<2 {
                    let x = CGFloat(9 + column * 6)
                    let y = CGFloat(6 + row * 6)
                    dots.append(FlowIcon.circle(FlowIcon.pt(x, y), 1.5))
                }
            }
            return FlowIconDrawing(fills: dots)

        case .mic:
            return FlowIconDrawing(strokes: [
                UIBezierPath(roundedRect: CGRect(x: 9, y: 2.5, width: 6, height: 11), cornerRadius: 3),
                FlowIcon.arc(FlowIcon.pt(12, 11), 6.0, 0, 180, clockwise: false),
                FlowIcon.line([FlowIcon.pt(12, 17), FlowIcon.pt(12, 21)]),
                FlowIcon.line([FlowIcon.pt(8, 21), FlowIcon.pt(16, 21)]),
            ])

        case .equalizer:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(5, 4), FlowIcon.pt(5, 20)]),
                FlowIcon.line([FlowIcon.pt(12, 4), FlowIcon.pt(12, 20)]),
                FlowIcon.line([FlowIcon.pt(19, 4), FlowIcon.pt(19, 20)]),
            ], fills: [
                FlowIcon.circle(FlowIcon.pt(5, 9), 2.0),
                FlowIcon.circle(FlowIcon.pt(12, 15), 2.0),
                FlowIcon.circle(FlowIcon.pt(19, 7), 2.0),
            ])

        case .wifi:
            return FlowIconDrawing(strokes: [
                FlowIcon.arc(FlowIcon.pt(12, 18), 10.0, 215, 325),
                FlowIcon.arc(FlowIcon.pt(12, 18), 6.5, 215, 325),
                FlowIcon.arc(FlowIcon.pt(12, 18), 3.0, 215, 325),
            ], fills: [
                FlowIcon.circle(FlowIcon.pt(12, 18.5), 1.6),
            ])

        case .moon:
            let crescent = UIBezierPath()
            crescent.move(to: FlowIcon.pt(20, 14.5))
            crescent.addCurve(to: FlowIcon.pt(9.5, 4), controlPoint1: FlowIcon.pt(18, 11.5), controlPoint2: FlowIcon.pt(14, 7))
            crescent.addCurve(to: FlowIcon.pt(20, 14.5), controlPoint1: FlowIcon.pt(17, 7.5), controlPoint2: FlowIcon.pt(21.5, 11))
            crescent.close()
            return FlowIconDrawing(strokes: [crescent])

        case .sun:
            var paths: [UIBezierPath] = [
                FlowIcon.circle(FlowIcon.pt(12, 12), 4.2),
            ]
            for index in 0..<8 {
                let angle = (CGFloat(index) / 8.0) * CGFloat.pi * 2.0
                let inner = FlowIcon.pt(12 + cos(angle) * 6.6, 12 + sin(angle) * 6.6)
                let outer = FlowIcon.pt(12 + cos(angle) * 9.2, 12 + sin(angle) * 9.2)
                paths.append(FlowIcon.line([inner, outer]))
            }
            return FlowIconDrawing(strokes: paths, strokeWidth: 1.8)

        case .chevronDown:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(6, 9), FlowIcon.pt(12, 15), FlowIcon.pt(18, 9)]),
            ])

        case .chevronRight:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(9, 5), FlowIcon.pt(16, 12), FlowIcon.pt(9, 19)]),
            ])

        case .filter:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(3, 5), FlowIcon.pt(21, 5), FlowIcon.pt(14, 13), FlowIcon.pt(14, 20), FlowIcon.pt(10, 18), FlowIcon.pt(10, 13), FlowIcon.pt(3, 5)]),
            ])

        case .sort:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(4, 6), FlowIcon.pt(20, 6)]),
                FlowIcon.line([FlowIcon.pt(4, 12), FlowIcon.pt(14, 12)]),
                FlowIcon.line([FlowIcon.pt(4, 18), FlowIcon.pt(9, 18)]),
            ])

        case .notes:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(5, 3), FlowIcon.pt(15, 3), FlowIcon.pt(19, 7), FlowIcon.pt(19, 21), FlowIcon.pt(5, 21), FlowIcon.pt(5, 3)]),
                FlowIcon.line([FlowIcon.pt(15, 3), FlowIcon.pt(15, 7), FlowIcon.pt(19, 7)]),
                FlowIcon.line([FlowIcon.pt(8.5, 12), FlowIcon.pt(15.5, 12)]),
                FlowIcon.line([FlowIcon.pt(8.5, 16), FlowIcon.pt(13.5, 16)]),
            ])

        case .recap:
            return FlowIconDrawing(strokes: [
                FlowIcon.circle(FlowIcon.pt(12, 12), 9),
                FlowIcon.line([FlowIcon.pt(12, 7), FlowIcon.pt(12, 12), FlowIcon.pt(16, 14)]),
            ], fills: [
                FlowIcon.circle(FlowIcon.pt(12, 12), 1.4),
            ])

        case .sync:
            return FlowIconDrawing(strokes: [
                FlowIcon.arc(FlowIcon.pt(12, 12), 8.0, 200, 340),
                FlowIcon.arc(FlowIcon.pt(12, 12), 8.0, 20, 160),
                FlowIcon.line([FlowIcon.pt(17.5, 4.5), FlowIcon.pt(18.5, 9), FlowIcon.pt(14, 8.5)]),
                FlowIcon.line([FlowIcon.pt(6.5, 19.5), FlowIcon.pt(5.5, 15), FlowIcon.pt(10, 15.5)]),
            ])

        case .importIcon:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(12, 3), FlowIcon.pt(12, 14)]),
                FlowIcon.line([FlowIcon.pt(7.5, 9.5), FlowIcon.pt(12, 14), FlowIcon.pt(16.5, 9.5)]),
                FlowIcon.line([FlowIcon.pt(4, 16), FlowIcon.pt(4, 20), FlowIcon.pt(20, 20), FlowIcon.pt(20, 16)]),
            ])

        case .exportIcon:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(12, 15), FlowIcon.pt(12, 4)]),
                FlowIcon.line([FlowIcon.pt(7.5, 8.5), FlowIcon.pt(12, 4), FlowIcon.pt(16.5, 8.5)]),
                FlowIcon.line([FlowIcon.pt(4, 16), FlowIcon.pt(4, 20), FlowIcon.pt(20, 20), FlowIcon.pt(20, 16)]),
            ])

        case .notification:
            let bell = UIBezierPath()
            bell.move(to: FlowIcon.pt(6, 17))
            bell.addLine(to: FlowIcon.pt(6, 10.5))
            bell.addCurve(to: FlowIcon.pt(18, 10.5), controlPoint1: FlowIcon.pt(6, 4), controlPoint2: FlowIcon.pt(18, 4))
            bell.addLine(to: FlowIcon.pt(18, 17))
            bell.addLine(to: FlowIcon.pt(20, 18.5))
            bell.addLine(to: FlowIcon.pt(4, 18.5))
            bell.close()
            return FlowIconDrawing(strokes: [
                bell,
                FlowIcon.arc(FlowIcon.pt(12, 19), 2.2, 0, 180, clockwise: false),
            ])

        case .verified:
            let badge = UIBezierPath()
            badge.move(to: FlowIcon.pt(12, 2))
            badge.addLine(to: FlowIcon.pt(14.6, 4.6))
            badge.addLine(to: FlowIcon.pt(18.2, 4.2))
            badge.addLine(to: FlowIcon.pt(18.6, 7.8))
            badge.addLine(to: FlowIcon.pt(21.2, 10.4))
            badge.addLine(to: FlowIcon.pt(19.4, 13.5))
            badge.addLine(to: FlowIcon.pt(19.4, 17.1))
            badge.addLine(to: FlowIcon.pt(15.8, 17.5))
            badge.addLine(to: FlowIcon.pt(13.2, 20.1))
            badge.addLine(to: FlowIcon.pt(10.1, 18.3))
            badge.addLine(to: FlowIcon.pt(6.5, 18.3))
            badge.addLine(to: FlowIcon.pt(6.1, 14.7))
            badge.addLine(to: FlowIcon.pt(3.5, 12.1))
            badge.addLine(to: FlowIcon.pt(5.3, 9.0))
            badge.addLine(to: FlowIcon.pt(5.3, 5.4))
            badge.addLine(to: FlowIcon.pt(8.9, 5.0))
            badge.close()
            return FlowIconDrawing(strokes: [
                badge,
                FlowIcon.line([FlowIcon.pt(8.5, 12.2), FlowIcon.pt(11, 14.7), FlowIcon.pt(15.8, 9.5)]),
            ], strokeWidth: 1.7)

        case .live:
            return FlowIconDrawing(strokes: [
                FlowIcon.arc(FlowIcon.pt(12, 12), 9.0, -50, 50),
                FlowIcon.arc(FlowIcon.pt(12, 12), 9.0, 130, 230),
                FlowIcon.arc(FlowIcon.pt(12, 12), 5.5, -50, 50),
                FlowIcon.arc(FlowIcon.pt(12, 12), 5.5, 130, 230),
            ], fills: [
                FlowIcon.circle(FlowIcon.pt(12, 12), 2.2),
            ])

        case .dislike:
            let thumb = FlowIcon.thumbsPath(pointingUp: false)
            return FlowIconDrawing(strokes: [thumb])

        case .comment:
            let bubble = UIBezierPath()
            bubble.move(to: FlowIcon.pt(3, 5))
            bubble.addLine(to: FlowIcon.pt(21, 5))
            bubble.addLine(to: FlowIcon.pt(21, 16))
            bubble.addLine(to: FlowIcon.pt(9, 16))
            bubble.addLine(to: FlowIcon.pt(4, 21))
            bubble.addLine(to: FlowIcon.pt(4, 16))
            bubble.addLine(to: FlowIcon.pt(3, 16))
            bubble.close()
            return FlowIconDrawing(strokes: [bubble])

        case .queue:
            return FlowIconDrawing(strokes: [
                FlowIcon.line([FlowIcon.pt(3, 6), FlowIcon.pt(14, 6)]),
                FlowIcon.line([FlowIcon.pt(3, 12), FlowIcon.pt(14, 12)]),
                FlowIcon.line([FlowIcon.pt(3, 18), FlowIcon.pt(10, 18)]),
                FlowIcon.line([FlowIcon.pt(18, 4), FlowIcon.pt(18, 14)]),
                FlowIcon.line([FlowIcon.pt(15.5, 11.5), FlowIcon.pt(18, 14), FlowIcon.pt(20.5, 11.5)]),
            ])
        }
    }

    /// Renders the glyph at `size` points.
    func image(size: CGFloat, color: UIColor = .black) -> UIImage {
        return drawing.image(size: size, color: color)
    }

    // MARK: - Path helpers

    static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        return CGPoint(x: x, y: y)
    }

    static func line(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> UIBezierPath {
        return UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: true)
    }

    static func arc(_ center: CGPoint, _ radius: CGFloat, _ startDegrees: CGFloat, _ endDegrees: CGFloat, clockwise: Bool = true) -> UIBezierPath {
        let start = startDegrees * CGFloat.pi / 180.0
        let end = endDegrees * CGFloat.pi / 180.0
        return UIBezierPath(arcCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    }

    static func triangle(center: CGPoint, width: CGFloat, height: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center.x - width / 2.0, y: center.y - height / 2.0))
        path.addLine(to: CGPoint(x: center.x + width / 2.0, y: center.y))
        path.addLine(to: CGPoint(x: center.x - width / 2.0, y: center.y + height / 2.0))
        path.close()
        return path
    }

    static func triangleFlipped(center: CGPoint, width: CGFloat, height: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center.x + width / 2.0, y: center.y - height / 2.0))
        path.addLine(to: CGPoint(x: center.x - width / 2.0, y: center.y))
        path.addLine(to: CGPoint(x: center.x + width / 2.0, y: center.y + height / 2.0))
        path.close()
        return path
    }

    static func heartPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: pt(12, 20.6))
        path.addCurve(to: pt(3.4, 10.4), controlPoint1: pt(9.4, 18.0), controlPoint2: pt(3.4, 15.0))
        path.addCurve(to: pt(12, 6.4), controlPoint1: pt(3.4, 5.8), controlPoint2: pt(8.0, 4.4))
        path.addCurve(to: pt(20.6, 10.4), controlPoint1: pt(16.0, 4.4), controlPoint2: pt(20.6, 5.8))
        path.addCurve(to: pt(12, 20.6), controlPoint1: pt(20.6, 15.0), controlPoint2: pt(14.6, 18.0))
        path.close()
        return path
    }

    static func thumbsPath(pointingUp: Bool) -> UIBezierPath {
        let path = UIBezierPath()
        if pointingUp {
            path.move(to: pt(3, 10))
            path.addLine(to: pt(7, 10))
            path.addLine(to: pt(7, 21))
            path.addLine(to: pt(3, 21))
            path.close()
            path.move(to: pt(9, 21))
            path.addLine(to: pt(9, 10))
            path.addLine(to: pt(12, 3))
            path.addCurve(to: pt(15, 6), controlPoint1: pt(13.6, 3), controlPoint2: pt(15, 4.2))
            path.addLine(to: pt(15, 9))
            path.addLine(to: pt(20, 9))
            path.addCurve(to: pt(19, 13), controlPoint1: pt(20.8, 9), controlPoint2: pt(19.5, 11))
            path.addLine(to: pt(17.4, 19))
            path.addCurve(to: pt(14.4, 21), controlPoint1: pt(17.0, 20.2), controlPoint2: pt(15.9, 21))
            path.addLine(to: pt(9, 21))
        } else {
            path.move(to: pt(3, 14))
            path.addLine(to: pt(7, 14))
            path.addLine(to: pt(7, 3))
            path.addLine(to: pt(3, 3))
            path.close()
            path.move(to: pt(9, 3))
            path.addLine(to: pt(9, 14))
            path.addLine(to: pt(12, 21))
            path.addCurve(to: pt(15, 18), controlPoint1: pt(13.6, 21), controlPoint2: pt(15, 19.8))
            path.addLine(to: pt(15, 15))
            path.addLine(to: pt(20, 15))
            path.addCurve(to: pt(19, 11), controlPoint1: pt(20.8, 15), controlPoint2: pt(19.5, 13))
            path.addLine(to: pt(17.4, 5))
            path.addCurve(to: pt(14.4, 3), controlPoint1: pt(17.0, 3.8), controlPoint2: pt(15.9, 3))
            path.addLine(to: pt(9, 3))
        }
        return path
    }
}

/// A view that draws one `FlowIcon` in its tint colour. Used wherever a button needs a glyph and a
/// `UIImageView` would add a layer for nothing.
final class FlowIconView: UIView {

    /// The glyph to draw, or nil for an empty view that is still laid out.
    var icon: FlowIcon? = .home {
        didSet { setNeedsDisplay() }
    }

    /// The glyph's colour. Defaults to the app's on-surface colour.
    var iconColor: UIColor = FlowTheme.shared.onSurface {
        didSet { setNeedsDisplay() }
    }

    /// The glyph's size inside the view. The view itself can be larger, for a bigger tap target.
    var iconSize: CGFloat = 24.0 {
        didSet { setNeedsDisplay() }
    }

    /// A filled background behind the glyph, e.g. for a circular action button.
    var badgeColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    /// Convenience constructor.
    static func make(_ icon: FlowIcon, color: UIColor, size: CGFloat = 24.0) -> FlowIconView {
        let view = FlowIconView()
        view.icon = icon
        view.iconColor = color
        view.iconSize = size
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if let badge = badgeColor {
            badge.setFill()
            UIBezierPath(ovalIn: bounds).fill()
        }
        let side = min(bounds.width, bounds.height, iconSize)
        let origin = CGPoint(x: bounds.midX - side / 2.0, y: bounds.midY - side / 2.0)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        let scale = side / 24.0
        context.scaleBy(x: scale, y: scale)
        guard let icon = icon else {
            context.restoreGState()
            return
        }
        iconColor.setStroke()
        iconColor.setFill()
        let drawing = icon.drawing
        for path in drawing.fills {
            path.fill()
        }
        for path in drawing.strokes {
            path.lineWidth = drawing.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        context.restoreGState()
    }

    /// Repaints when the palette changes.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsDisplay()
        }
    }
}

/// A button whose only content is a `FlowIcon`, with a proper 48-point tap target.
final class FlowIconButton: UIButton {

    private let iconView = FlowIconView()
    private var icon: FlowIcon = .more
    private var iconColor: UIColor = FlowTheme.shared.onSurface
    private var iconSize: CGFloat = 24.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        addSubviewForAutoLayout(iconView)
        iconView.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        widthAnchor.constraint(greaterThanOrEqualToConstant: 44.0).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0).isActive = true
        accessibilityTraits = .button
    }

    /// Creates a button for `icon`.
    static func make(_ icon: FlowIcon, color: UIColor, size: CGFloat = 24.0, target: Any?, action: Selector) -> FlowIconButton {
        let button = FlowIconButton()
        button.configure(icon: icon, color: color, size: size)
        button.addTarget(target, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Sets the glyph, colour and size.
    func configure(icon: FlowIcon, color: UIColor, size: CGFloat = 24.0) {
        self.icon = icon
        iconColor = color
        iconSize = size
        iconView.icon = icon
        iconView.iconColor = color
        iconView.iconSize = size
        iconView.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// Changes the glyph after creation, e.g. play to pause.
    func setIcon(_ icon: FlowIcon) {
        self.icon = icon
        iconView.icon = icon
    }

    /// Changes the glyph's colour, e.g. to the accent when active.
    func setIconColor(_ color: UIColor) {
        iconColor = color
        iconView.iconColor = color
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : 1.0
        }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1.0 : 0.38
        }
    }
}
