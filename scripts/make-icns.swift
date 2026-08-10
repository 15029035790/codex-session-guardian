import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-icns.swift ICONSET OUTPUT\n", stderr)
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let entries = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

var elements = Data()
for (type, filename) in entries {
    let png = try Data(contentsOf: iconset.appendingPathComponent(filename))
    elements.append(Data(type.utf8))
    appendBigEndian(UInt32(png.count + 8), to: &elements)
    elements.append(png)
}

var result = Data("icns".utf8)
appendBigEndian(UInt32(elements.count + 8), to: &result)
result.append(elements)
try result.write(to: output, options: .atomic)
