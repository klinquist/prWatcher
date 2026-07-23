#!/usr/bin/env swift

import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: create-icns.swift <iconset-directory> <output.icns>\n".utf8))
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])
let representations: [(type: String, filename: String)] = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func fourCharacterCode(_ value: String) -> Data {
    precondition(value.utf8.count == 4)
    return Data(value.utf8)
}

func bigEndianData(_ value: Int) -> Data {
    var integer = UInt32(value).bigEndian
    return withUnsafeBytes(of: &integer) { Data($0) }
}

var elements = Data()
for representation in representations {
    let imageURL = iconsetURL.appendingPathComponent(representation.filename)
    let imageData = try Data(contentsOf: imageURL)
    elements.append(fourCharacterCode(representation.type))
    elements.append(bigEndianData(imageData.count + 8))
    elements.append(imageData)
}

var iconData = Data("icns".utf8)
iconData.append(bigEndianData(elements.count + 8))
iconData.append(elements)
try iconData.write(to: outputURL, options: .atomic)

print("Wrote \(outputURL.path) with \(representations.count) representations")
