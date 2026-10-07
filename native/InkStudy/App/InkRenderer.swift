import UIKit
import InkStudyCore

@MainActor
enum InkRenderer {
    static func color(_ hex: String) -> UIColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func draw(_ stroke: InkStroke, in context: CGContext, neutral: Bool = false) {
        context.setFillColor(color(stroke.style.color.hex).cgColor)
        context.addPath(path(samples: stroke.samples[...], style: stroke.style, neutral: neutral)); context.fillPath()
    }

    static func path(samples: ArraySlice<TouchSample>, style: BrushStyle, neutral: Bool = false) -> CGPath {
        let path = CGMutablePath()
        var previous: (point: CGPoint, radius: Double)?
        for sample in samples {
            let point = CGPoint(x: sample.x, y: sample.y)
            let radius = neutral ? 6 : PressureMapping.diameter(style: style, normalizedForce: sample.normalizedForce) / 2
            if let last = previous {
                let dx = point.x - last.point.x, dy = point.y - last.point.y
                let distance = hypot(dx, dy)
                if distance > 0.0001 {
                    let nx = -dy / distance, ny = dx / distance
                    // Match the ellipse winding so overlapping joins form a union, not holes.
                    path.move(to: CGPoint(x: last.point.x - nx * last.radius, y: last.point.y - ny * last.radius))
                    path.addLine(to: CGPoint(x: point.x - nx * radius, y: point.y - ny * radius))
                    path.addLine(to: CGPoint(x: point.x + nx * radius, y: point.y + ny * radius))
                    path.addLine(to: CGPoint(x: last.point.x + nx * last.radius, y: last.point.y + ny * last.radius))
                    path.closeSubpath()
                }
            }
            path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            previous = (point, radius)
        }
        return path
    }

    static func artwork(_ state: DrawingState, scale: CGFloat = 2) -> UIImage {
        let size = CGSize(width: state.metadata.paperWidth, height: state.metadata.paperHeight)
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            BackgroundRenderer.draw(state.metadata, in: renderer.cgContext, pass: .background)
            if state.metadata.background?.kind == "pigment" {
                PigmentRenderer.image(PigmentSurface(state: state)).draw(in: CGRect(origin: .zero, size: size))
            } else {
                for stroke in state.visibleStrokes { draw(stroke, in: renderer.cgContext, neutral: state.metadata.neutralRendering == true) }
            }
            BackgroundRenderer.draw(state.metadata, in: renderer.cgContext, pass: .foreground)
        }
    }

    static func background(_ metadata: DocumentMetadata, includeOutline: Bool = true) -> UIImage {
        let size = CGSize(width: metadata.paperWidth, height: metadata.paperHeight)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            BackgroundRenderer.draw(metadata, in: renderer.cgContext, pass: includeOutline ? .all : .background)
        }
    }

    static func foreground(_ metadata: DocumentMetadata) -> UIImage {
        let size = CGSize(width: metadata.paperWidth, height: metadata.paperHeight)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            BackgroundRenderer.draw(metadata, in: renderer.cgContext, pass: .foreground)
        }
    }
}
