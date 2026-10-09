import AppKit
import Foundation

// Deterministic legacy-ICNS packaging, not a redesign of the supplied artwork.
// Project policy: 100/1024 transparent inset per side (824/1024 artwork width).
// This is a compatibility target pending older-macOS visual acceptance, not an Apple API rule.
let sizes = ["icon_16x16": 16, "icon_16x16@2x": 32, "icon_32x32": 32,
             "icon_32x32@2x": 64, "icon_128x128": 128, "icon_128x128@2x": 256,
             "icon_256x256": 256, "icon_256x256@2x": 512,
             "icon_512x512": 512, "icon_512x512@2x": 1024]
let fm = FileManager.default
struct IconFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw IconFailure(description: message) }
}
func run(_ arguments: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = arguments
    try task.run(); task.waitUntilExit()
    try require(task.terminationStatus == 0, "iconutil failed: \(task.terminationStatus)")
}
func scratch<T>(_ body: (URL) throws -> T) throws -> T {
    let url = fm.temporaryDirectory.appendingPathComponent("leftopen-icon-\(UUID().uuidString)")
    try fm.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: url) }
    return try body(url)
}
func decode(_ file: URL, size: Int) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw IconFailure(description: "Cannot decode \(file.lastPathComponent)")
    }
    try require(image.width == size && image.height == size, "Wrong pixel dimensions: \(file.lastPathComponent)")
    return image
}
func context(_ size: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw IconFailure(description: "Cannot allocate image")
    }
    return context
}
func pixels(_ image: CGImage) throws -> [UInt8] {
    let c = try context(image.width)
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}
func bounds(_ data: [UInt8], size: Int, threshold: UInt8) -> [Int] {
    var left = size, bottom = size, right = -1, top = -1
    for y in 0..<size { for x in 0..<size where data[(y * size + x) * 4 + 3] >= threshold {
        left = min(left, x); right = max(right, x); bottom = min(bottom, y); top = max(top, y)
    } }
    return right < 0 ? [] : [left, bottom, right + 1, top + 1]
}
func padded(_ image: CGImage) throws -> CGImage {
    let size = image.width
    let inset = Int((Double(size) * 100 / 1024).rounded())
    let c = try context(size)
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2))
    return c.makeImage()!
}
func save(_ image: CGImage, to file: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw IconFailure(description: "Cannot encode PNG")
    }
    try data.write(to: file)
}
func extract(_ file: URL, into directory: URL) throws {
    try run(["-c", "iconset", file.path, "-o", directory.path])
    let names = Set(try fm.contentsOfDirectory(atPath: directory.path))
    try require(names == Set(sizes.keys.map { $0 + ".png" }), "Missing or unexpected icon representations")
}
func generate(_ source: URL, _ output: URL) throws {
    try require(!fm.fileExists(atPath: output.path), "Refusing to overwrite an existing icon")
    try scratch { dir in
        let input = dir.appendingPathComponent("input.iconset")
        let result = dir.appendingPathComponent("result.iconset")
        try extract(source, into: input)
        try fm.createDirectory(at: result, withIntermediateDirectories: false)
        for (name, size) in sizes {
            let image = try decode(input.appendingPathComponent(name + ".png"), size: size)
            // Fail if the source is already padded: prevents accidental double-insetting.
            try require(bounds(try pixels(image), size: size, threshold: 128) == [0, 0, size, size],
                        "Source no longer full-bleed; review padding policy before packaging")
            try save(padded(image), to: result.appendingPathComponent(name + ".png"))
        }
        try run(["-c", "icns", result.path, "-o", output.path])
    }
}
func audit(_ source: URL) throws {
    try scratch { dir in
        let input = dir.appendingPathComponent("audit.iconset")
        try extract(source, into: input)
        for name in sizes.keys.sorted() {
            let size = sizes[name]!, image = try decode(input.appendingPathComponent(name + ".png"), size: sizes[name]!)
            let data = try pixels(image)
            print("\(name) \(size)px alpha1=\(bounds(data, size: size, threshold: 1)) alpha128=\(bounds(data, size: size, threshold: 128)) alpha250=\(bounds(data, size: size, threshold: 250))")
        }
    }
}
func verify(_ source: URL, _ app: URL) throws {
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
    try require(info?["CFBundleIconFile"] as? String == "AppIcon", "Unexpected CFBundleIconFile")
    try require(info?["CFBundleIconName"] == nil && info?["CFBundleIcons"] == nil,
                "An alternate icon selector needs explicit verification")
    try require(!fm.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Assets.car").path),
                "Asset-catalog icon integration needs explicit verification")
    try scratch { dir in
        let referenceFile = dir.appendingPathComponent("reference.icns")
        let reference = dir.appendingPathComponent("reference.iconset")
        let actual = dir.appendingPathComponent("actual.iconset")
        // Canonicalize through the same ICNS encoder. Small legacy representations
        // have different color/alpha encoding from PNG, so compare decoded ICNS to ICNS.
        try generate(source, referenceFile)
        try extract(referenceFile, into: reference)
        try extract(app.appendingPathComponent("Contents/Resources/AppIcon.icns"), into: actual)
        for (name, size) in sizes {
            let referenceImage = try decode(reference.appendingPathComponent(name + ".png"), size: size)
            let actualImage = try decode(actual.appendingPathComponent(name + ".png"), size: size)
            let expected = try pixels(referenceImage), received = try pixels(actualImage)
            let difference = zip(expected, received).map { abs(Int($0) - Int($1)) }.max() ?? 0
            try require(difference == 0, "Packaged pixels differ from padding-only transform: \(name), max channel delta \(difference)")
            let inset = Int((Double(size) * 100 / 1024).rounded())
            let box = bounds(received, size: size, threshold: 128)
            try require(box.count == 4 && box[0] >= inset && box[1] >= inset && box[2] <= size-inset && box[3] <= size-inset,
                        "Missing transparent margin: \(name)")
        }
        print("Verified icon selector, all 10 sizes, transparent margins and unchanged artwork transform")
    }
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "generate" where args.count == 3: try generate(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]))
    case "verify" where args.count == 3: try verify(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]))
    case "audit" where args.count == 2: try audit(URL(fileURLWithPath: args[1]))
    default: throw IconFailure(description: "Usage: legacy-app-icon.swift audit source.icns | generate source.icns output.icns | verify source.icns app")
    }
} catch {
    FileHandle.standardError.write(Data("Icon check failed: \(error)\n".utf8))
    exit(1)
}
