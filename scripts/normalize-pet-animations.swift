#!/usr/bin/env swift

import AppKit
import Foundation

private struct SequenceSource {
    let id: String
    let directory: URL
    let fileNames: [String]
    let visibleHeight: CGFloat
}

private struct Raster {
    let image: CGImage
    var pixels: [UInt8]
    let width: Int
    let height: Int
}

private struct PixelBounds {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }

    mutating func include(_ other: PixelBounds) {
        minX = min(minX, other.minX)
        minY = min(minY, other.minY)
        maxX = max(maxX, other.maxX)
        maxY = max(maxY, other.maxY)
    }
}

private enum NormalizeError: LocalizedError {
    case invalidArguments
    case unreadableImage(String)
    case emptyAlpha(String)
    case inconsistentCanvas(String)
    case contentTooWide(String, Double)
    case normalizationMismatch(String, String)
    case pngEncoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "用法：swift scripts/normalize-pet-animations.swift <小新 output 目录> <动感超人原帧目录> <输出目录>"
        case let .unreadableImage(path): return "无法读取图片：\(path)"
        case let .emptyAlpha(path): return "未检测到有效 alpha 内容：\(path)"
        case let .inconsistentCanvas(id): return "同一序列的原始画布尺寸不一致：\(id)"
        case let .contentTooWide(id, width):
            return "序列 \(id) 按统一可见高度缩放后宽度为 \(String(format: "%.1f", width))，超过规范画布"
        case let .normalizationMismatch(id, detail): return "序列 \(id) 归一化校验失败：\(detail)"
        case let .pngEncoding(path): return "无法编码 PNG：\(path)"
        }
    }
}

private let canvasSize = NSSize(width: 106, height: 116)
private let footBaseline: CGFloat = 10
private let horizontalInset: CGFloat = 2
private let alphaThreshold: UInt8 = 8

private func rasterize(_ image: NSImage, path: String) throws -> Raster {
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
        throw NormalizeError.unreadableImage(path)
    }
    let width = source.width
    let height = source.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw NormalizeError.unreadableImage(path) }
    context.interpolationQuality = .none
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let normalized = context.makeImage() else { throw NormalizeError.unreadableImage(path) }
    return Raster(image: normalized, pixels: pixels, width: width, height: height)
}

private func makeImage(from raster: Raster, path: String) throws -> CGImage {
    var pixels = raster.pixels
    guard let context = CGContext(
        data: &pixels,
        width: raster.width,
        height: raster.height,
        bitsPerComponent: 8,
        bytesPerRow: raster.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        let image = context.makeImage()
    else { throw NormalizeError.unreadableImage(path) }
    return image
}

private func removeBakedCheckerboard(_ input: Raster, path: String) throws -> Raster {
    // The supplied PNGs visually contain a transparency checkerboard but are
    // actually opaque indexed-color images. Preserve genuine alpha assets and
    // only key opaque canvases. Flood filling from the outer edge prevents the
    // same pale palette colors inside Shin-chan's eyes, skin and shorts from
    // being erased.
    guard !stride(from: 3, to: input.pixels.count, by: 4)
        .contains(where: { input.pixels[$0] < 250 })
    else {
        return input
    }

    var output = input
    let count = output.width * output.height
    var background = [Bool](repeating: false, count: count)
    var queue = [Int]()
    queue.reserveCapacity(count)

    func isCheckerPixel(_ pixel: Int) -> Bool {
        let offset = pixel * 4
        let lightChannels = [
            output.pixels[offset], output.pixels[offset + 1], output.pixels[offset + 2],
        ].reduce(0) { $0 + ($1 >= 208 ? 1 : 0) }
        return lightChannels >= 2
    }

    func enqueue(_ x: Int, _ y: Int) {
        let pixel = y * output.width + x
        guard !background[pixel], isCheckerPixel(pixel) else { return }
        background[pixel] = true
        queue.append(pixel)
    }

    for x in 0..<output.width {
        enqueue(x, 0)
        enqueue(x, output.height - 1)
    }
    for y in 0..<output.height {
        enqueue(0, y)
        enqueue(output.width - 1, y)
    }

    var cursor = 0
    while cursor < queue.count {
        let pixel = queue[cursor]
        cursor += 1
        let x = pixel % output.width
        let y = pixel / output.width
        if x > 0 { enqueue(x - 1, y) }
        if x + 1 < output.width { enqueue(x + 1, y) }
        if y > 0 { enqueue(x, y - 1) }
        if y + 1 < output.height { enqueue(x, y + 1) }
    }

    for pixel in 0..<count where background[pixel] {
        let offset = pixel * 4
        output.pixels[offset] = 0
        output.pixels[offset + 1] = 0
        output.pixels[offset + 2] = 0
        output.pixels[offset + 3] = 0
    }
    return Raster(
        image: try makeImage(from: output, path: path),
        pixels: output.pixels,
        width: output.width,
        height: output.height)
}

private func alphaBounds(_ raster: Raster, path: String) throws -> PixelBounds {
    var bounds: PixelBounds?
    for y in 0..<raster.height {
        for x in 0..<raster.width {
            guard raster.pixels[(y * raster.width + x) * 4 + 3] >= alphaThreshold else { continue }
            let point = PixelBounds(minX: x, minY: y, maxX: x, maxY: y)
            if bounds == nil { bounds = point } else { bounds!.include(point) }
        }
    }
    guard let bounds else { throw NormalizeError.emptyAlpha(path) }
    return bounds
}

private func normalizedPNG(cropped: CGImage, sequenceID: String, visibleHeight: CGFloat) throws -> Data {
    let scale = visibleHeight / CGFloat(cropped.height)
    let drawWidth = CGFloat(cropped.width) * scale
    guard drawWidth <= canvasSize.width - horizontalInset * 2 else {
        throw NormalizeError.contentTooWide(sequenceID, Double(drawWidth))
    }

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width),
        pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw NormalizeError.pngEncoding(sequenceID) }

    bitmap.size = canvasSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(origin: .zero, size: canvasSize))
    graphics.imageInterpolation = .high
    let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    image.draw(
        in: NSRect(
            x: (canvasSize.width - drawWidth) / 2,
            y: footBaseline,
            width: drawWidth,
            height: visibleHeight),
        from: NSRect(origin: .zero, size: image.size),
        operation: .sourceOver,
        fraction: 1)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NormalizeError.pngEncoding(sequenceID)
    }
    return data
}

private func imageNames(start: Int, count: Int, format: String = "output%d.png") -> [String] {
    (start..<(start + count)).map { String(format: format, $0) }
}

private func process(_ source: SequenceSource, outputRoot: URL) throws -> [String: Any] {
    let loaded: [(URL, Raster)] = try source.fileNames.map { name in
        let url = source.directory.appendingPathComponent(name)
        guard let image = NSImage(contentsOf: url) else { throw NormalizeError.unreadableImage(url.path) }
        let raster = try rasterize(image, path: url.path)
        return (url, try removeBakedCheckerboard(raster, path: url.path))
    }

    guard let first = loaded.first?.1,
          loaded.allSatisfy({ $0.1.width == first.width && $0.1.height == first.height })
    else { throw NormalizeError.inconsistentCanvas(source.id) }

    var union = try alphaBounds(first, path: loaded[0].0.path)
    for (url, raster) in loaded.dropFirst() {
        union.include(try alphaBounds(raster, path: url.path))
    }

    let outputDirectory = outputRoot.appendingPathComponent(source.id, isDirectory: true)
    if FileManager.default.fileExists(atPath: outputDirectory.path) {
        try FileManager.default.removeItem(at: outputDirectory)
    }
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    var normalizedUnion: PixelBounds?
    for (index, item) in loaded.enumerated() {
        let rect = CGRect(x: union.minX, y: union.minY, width: union.width, height: union.height)
        guard let cropped = item.1.image.cropping(to: rect) else {
            throw NormalizeError.unreadableImage(item.0.path)
        }
        let data = try normalizedPNG(
            cropped: cropped,
            sequenceID: source.id,
            visibleHeight: source.visibleHeight)
        let destination = outputDirectory.appendingPathComponent(String(format: "frame-%02d.png", index))
        try data.write(to: destination, options: .atomic)
        guard let normalizedImage = NSImage(data: data) else {
            throw NormalizeError.unreadableImage(destination.path)
        }
        let normalizedRaster = try rasterize(normalizedImage, path: destination.path)
        guard normalizedRaster.width == Int(canvasSize.width),
              normalizedRaster.height == Int(canvasSize.height)
        else {
            throw NormalizeError.normalizationMismatch(source.id, "画布尺寸不一致")
        }
        let bounds = try alphaBounds(normalizedRaster, path: destination.path)
        if normalizedUnion == nil { normalizedUnion = bounds } else { normalizedUnion!.include(bounds) }
    }

    guard let normalizedUnion,
          normalizedUnion.height == Int(source.visibleHeight),
          Int(canvasSize.height) - 1 - normalizedUnion.maxY == Int(footBaseline)
    else {
        throw NormalizeError.normalizationMismatch(source.id, "可见高度或脚底基线不一致")
    }

    return [
        "id": source.id,
        "frameCount": loaded.count,
        "sourceCanvas": ["width": first.width, "height": first.height],
        "alphaUnion": [
            "x": union.minX, "y": union.minY, "width": union.width, "height": union.height,
        ],
        "normalized": [
            "canvasWidth": Int(canvasSize.width),
            "canvasHeight": Int(canvasSize.height),
            "visibleHeight": Int(source.visibleHeight),
            "footBaseline": Int(footBaseline),
            "alphaUnion": [
                "x": normalizedUnion.minX,
                "y": normalizedUnion.minY,
                "width": normalizedUnion.width,
                "height": normalizedUnion.height,
            ],
        ],
    ]
}

do {
    guard CommandLine.arguments.count == 4 else { throw NormalizeError.invalidArguments }
    let shinchanRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let actionKamenRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let outputRoot = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

    let sources = [
        SequenceSource(
            id: "idle",
            directory: shinchanRoot.appendingPathComponent("1", isDirectory: true),
            fileNames: imageNames(start: 1, count: 6),
            visibleHeight: 68),
        SequenceSource(
            id: "multitask",
            directory: shinchanRoot.appendingPathComponent("2", isDirectory: true),
            fileNames: imageNames(start: 0, count: 8),
            visibleHeight: 68),
        SequenceSource(
            id: "success",
            directory: shinchanRoot.appendingPathComponent("4", isDirectory: true),
            fileNames: imageNames(start: 0, count: 12),
            visibleHeight: 68),
        SequenceSource(
            id: "working",
            directory: shinchanRoot.appendingPathComponent("5", isDirectory: true),
            fileNames: imageNames(start: 0, count: 4),
            visibleHeight: 68),
        SequenceSource(
            id: "thinking",
            directory: shinchanRoot.appendingPathComponent("6", isDirectory: true),
            fileNames: imageNames(start: 0, count: 10),
            visibleHeight: 68),
        SequenceSource(
            id: "guardian",
            directory: actionKamenRoot,
            fileNames: imageNames(start: 0, count: 5),
            visibleHeight: 82),
    ]

    let records = try sources.map { try process($0, outputRoot: outputRoot) }
    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "sequences": records,
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: outputRoot.appendingPathComponent("manifest.json"), options: .atomic)
    print("已归一化 \(records.count) 套序列帧到 \(outputRoot.path)")
    for record in records {
        let id = record["id"] as! String
        let count = record["frameCount"] as! Int
        let alpha = record["alphaUnion"] as! [String: Int]
        print("\(id): \(count) 帧，alpha 联合边界 \(alpha["width"]!)×\(alpha["height"]!)")
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
    exit(1)
}
