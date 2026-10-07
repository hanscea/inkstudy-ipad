import UIKit
import InkStudyCore

@MainActor
enum BackgroundRenderer {
    enum Pass { case all, background, foreground }
    static let subjects = ["cat", "dog", "bird", "flower", "tree", "grass"]
    static let names = ["cat": "小猫", "dog": "小狗", "bird": "小鸟", "flower": "花朵", "tree": "树木", "grass": "小草"]
    static func draw(_ metadata: DocumentMetadata, in context: CGContext, pass: Pass = .all) {
        guard let background = metadata.background else { return }
        guard background.kind == "guide" || background.kind == "outline" else { return }
        if background.kind == "outline", pass == .background { return }
        if background.kind == "guide", pass == .foreground { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setLineCap(.round); context.setLineJoin(.round)
        if background.kind == "guide" {
            let points = LineExercises.path(kind: background.subject, reverse: background.reverse, width: metadata.paperWidth, height: metadata.paperHeight)
            let path = CGMutablePath(); path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            let guideColor = UIColor(red: 0.32, green: 0.52, blue: 0.46, alpha: 1)
            if metadata.neutralRendering == true {
                context.setStrokeColor(guideColor.withAlphaComponent(0.35).cgColor)
                context.setLineWidth(5); context.addPath(path); context.strokePath()
            } else {
                let diameters = points.indices.map { index in
                    PressureMapping.diameter(style: .init(size: 80), normalizedForce:
                        background.pressureProfile?.force(at: Double(index) / Double(points.count - 1)) ?? background.target ?? 0.3)
                }
                let silhouette = guideShape(points: points, diameters: diameters)
                context.setFillColor(guideColor.withAlphaComponent(0.16).cgColor)
                context.addPath(silhouette); context.fillPath()
                context.setStrokeColor(guideColor.withAlphaComponent(0.64).cgColor)
                context.setLineWidth(1.8); context.addPath(silhouette); context.strokePath()
            }
            context.setLineWidth(2); context.setLineDash(phase: 0, lengths: [9, 10]); context.setStrokeColor(UIColor.gray.withAlphaComponent(0.45).cgColor)
            context.addPath(path); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(UIColor(red: 0.24, green: 0.44, blue: 0.39, alpha: 0.7).cgColor)
            context.fillEllipse(in: CGRect(x: points[0].x - 9, y: points[0].y - 9, width: 18, height: 18))
            return
        }
        let assessmentForm = background.subject.hasPrefix("form-")
        let height = assessmentForm ? 560.0 : 650.0
        let scale = min((metadata.paperWidth - 120) / 900, (metadata.paperHeight - 120) / height)
        context.translateBy(x: (metadata.paperWidth - 900 * scale) / 2, y: (metadata.paperHeight - height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(UIColor(red: 0.141, green: 0.192, blue: 0.169, alpha: 1).cgColor); context.setLineWidth(assessmentForm ? 7 : 5)
        let paths: [String]
        if background.subject.hasPrefix("form-") {
            paths = assessment[background.subject] ?? assessment["form-A"]!
        } else { paths = familiar[background.subject] ?? familiar["cat"]! }
        for specification in paths { context.addPath(svgPath(specification)); context.strokePath() }
        if assessmentForm {
            for x in [365.0, 555.0] { context.strokeEllipse(in: CGRect(x: x - 19, y: 264, width: 38, height: 38)) }
        }
    }

    static func guideShape(points: [ResearchPoint], diameters: [Double]) -> CGPath {
        guard points.count > 1, points.count == diameters.count else { return CGMutablePath() }
        var left: [CGPoint] = [], right: [CGPoint] = [], tangents: [CGPoint] = []
        for index in points.indices {
            let before = points[max(0, index - 1)], after = points[min(points.count - 1, index + 1)]
            let length = max(0.0001, hypot(after.x - before.x, after.y - before.y))
            let tangent = CGPoint(x: (after.x - before.x) / length, y: (after.y - before.y) / length)
            let radius = diameters[index] / 2, point = points[index]
            tangents.append(tangent)
            left.append(CGPoint(x: point.x - tangent.y * radius, y: point.y + tangent.x * radius))
            right.append(CGPoint(x: point.x + tangent.y * radius, y: point.y - tangent.x * radius))
        }
        let path = CGMutablePath(); path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        let last = points.count - 1
        path.addQuadCurve(to: right[last], control: CGPoint(x: points[last].x + tangents[last].x * diameters[last],
            y: points[last].y + tangents[last].y * diameters[last]))
        for point in right.dropLast().reversed() { path.addLine(to: point) }
        path.addQuadCurve(to: left[0], control: CGPoint(x: points[0].x - tangents[0].x * diameters[0],
            y: points[0].y - tangents[0].y * diameters[0]))
        path.closeSubpath(); return path
    }

    // These study outlines preserve the three existing assessment forms; familiar outlines are selectable in training.
    private static let assessment: [String: [String]] = [
        "form-A": [
            "M266 435 C185 390 170 280 240 214 C275 180 326 166 375 177 C415 112 493 104 538 161 C603 142 673 176 694 235 C720 307 677 391 603 420 C514 455 357 462 266 435Z",
            "M375 177 C349 124 366 77 407 52 C441 92 446 130 430 169", "M538 161 C575 112 623 103 661 128 C641 176 609 200 569 203",
            "M278 236 C236 204 188 209 158 248 C194 279 228 286 259 275", "M631 240 C689 212 742 228 767 275 C725 303 685 306 650 282",
            "M424 337 C454 359 494 359 523 334", "M305 426 C284 471 294 510 330 529 C356 501 362 469 348 444", "M574 435 C573 480 595 513 633 521 C647 484 638 454 613 426"
        ],
        "form-B": [
            "M269 405 Q210 332 241 227 Q274 156 348 157 L553 157 Q651 166 677 245 Q699 345 618 414 Q454 474 269 405Z",
            "M325 162 Q283 115 309 62 Q369 72 384 156", "M532 157 Q559 69 614 61 Q640 115 592 171", "M243 247 Q186 221 155 272 Q179 318 232 305",
            "M678 247 Q733 214 766 265 Q751 313 683 306", "M413 334 Q464 315 517 337", "M306 422 Q253 452 277 511 Q329 536 358 440", "M560 438 Q582 528 635 510 Q660 456 609 419"
        ],
        "form-C": [
            "M267 403 C190 329 229 238 293 211 C318 138 409 124 457 162 C528 121 611 160 622 224 C701 266 698 356 634 403 C548 459 354 463 267 403Z",
            "M324 177 Q290 111 344 65 Q403 107 392 150", "M516 148 Q512 86 574 69 Q618 125 580 178", "M260 240 Q183 236 161 301 Q217 337 251 299",
            "M651 244 Q724 235 755 294 Q709 338 671 305", "M416 345 Q456 371 516 342", "M311 425 Q318 489 283 510 Q348 538 380 445", "M534 445 Q566 536 622 511 Q593 475 605 425"
        ]
    ]
    private static let familiar: [String: [String]] = [
        "cat": ["M290 230 L270 90 L390 150 Q460 130 510 150 L640 90 L625 240 C690 430 230 430 290 230Z", "M360 330 Q290 500 340 555 L560 555 Q610 485 545 335", "M340 555 L410 555 L410 475 M490 475 L490 555 L560 555", "M558 485 C730 490 710 355 660 390", "M350 240 Q370 225 390 240 M520 240 Q540 225 560 240", "M435 280 L465 280 L450 295Z M450 295 Q430 320 409 305 M450 295 Q473 320 494 305", "M345 282 L235 265 M342 302 L235 310 M558 282 L675 265 M558 302 L675 310"],
        "dog": ["M330 170 C370 100 530 100 570 170 L600 300 Q590 390 450 390 Q300 390 300 300Z", "M335 150 C180 110 230 385 310 320 M565 150 C725 110 670 385 590 320", "M350 365 Q310 450 335 555 L565 555 Q600 450 550 365", "M400 240 L401 245 M500 240 L501 245 M425 300 Q450 280 475 300 L450 320Z M450 320 Q425 350 400 330 M450 320 Q475 350 500 330", "M405 465 L405 555 M495 465 L495 555 M565 480 Q680 420 650 365"],
        "bird": ["M250 330 C220 210 350 130 460 200 C525 110 650 150 650 245 L735 285 L650 315 C600 470 390 530 270 430 L160 445Z", "M310 330 Q455 250 525 355 Q420 435 310 330Z", "M591 228 L592 233 M650 245 L645 310 M390 465 L380 545 L345 560 M380 545 L414 558 M490 464 L490 540 L458 560 M490 540 L524 555"],
        "flower": ["M450 190 C350 30 260 170 375 255 C210 220 250 390 390 335 C320 510 505 510 515 360 C650 470 740 300 575 280 C745 175 615 70 510 200 C560 30 350 35 450 190Z", "M450 220 C530 190 590 275 545 330 C490 405 365 325 420 255 C428 240 438 228 450 220Z", "M480 370 Q430 470 480 590", "M465 490 Q335 395 330 470 Q385 560 469 535 M477 535 Q590 440 615 485 Q590 575 480 570"],
        "tree": ["M335 330 C175 345 190 165 310 175 C320 20 515 15 540 150 C720 90 760 285 630 325 C580 400 425 400 335 330Z", "M410 365 L395 550 L530 550 L510 370 M453 480 L450 325 M450 415 L385 360 M451 450 L530 385", "M250 565 Q430 525 655 568 M265 562 L242 525 M283 558 L290 512 M627 561 L650 515"],
        "grass": ["M220 540 Q205 325 110 260 Q300 305 318 495 Q315 240 245 135 Q440 285 425 490 Q475 160 460 70 Q555 210 540 485 Q680 255 708 143 Q775 340 652 517 Q778 407 820 400 L760 560 Q490 625 220 540Z", "M319 505 Q290 365 255 295 M425 490 Q419 345 374 279 M540 485 Q567 285 510 205 M652 517 Q716 403 737 330"]
    ]

    private static func svgPath(_ value: String) -> CGPath {
        let tokens = value.replacingOccurrences(of: "([A-Za-z])", with: " $1 ", options: .regularExpression)
            .split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let path = CGMutablePath(); var index = 0
        func point() -> CGPoint {
            defer { index += 2 }
            return CGPoint(x: Double(tokens[index]) ?? 0, y: Double(tokens[index + 1]) ?? 0)
        }
        while index < tokens.count {
            let command = tokens[index]; index += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "Q": let control = point(); path.addQuadCurve(to: point(), control: control)
            case "C": let first = point(), second = point(); path.addCurve(to: point(), control1: first, control2: second)
            case "Z": path.closeSubpath()
            default: return path
            }
        }
        return path
    }
}
