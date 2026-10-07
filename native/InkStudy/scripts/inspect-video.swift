import Foundation
import AVFoundation
import AppKit

guard CommandLine.arguments.count >= 3 else {
    fatalError("Usage: swift inspect-video.swift video-path output-directory [frame-count]")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let count = max(2, Int(CommandLine.arguments.dropFirst(3).first ?? "12") ?? 12)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let asset = AVURLAsset(url: source)
let duration = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 1100, height: 1100)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
print("Duration: \(duration) seconds")
for index in 0..<count {
    let seconds = min(duration - 0.1, Double(index) * duration / Double(count))
    let image = try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    let name = String(format: "frame-%02d-%06.2fs.png", index, seconds)
    try data.write(to: output.appendingPathComponent(name))
    print(name)
}
