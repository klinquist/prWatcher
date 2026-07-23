#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: process-app-icon.swift <source.png> <output.png>\n".utf8))
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let outputSize = 1024

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    FileHandle.standardError.write(Data("Could not read or prepare the source image.\n".utf8))
    exit(1)
}

var pixelStorage = Array(repeating: UInt8(0), count: outputSize * outputSize * 4)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue

guard let context = CGContext(
    data: &pixelStorage,
    width: outputSize,
    height: outputSize,
    bitsPerComponent: 8,
    bytesPerRow: outputSize * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    FileHandle.standardError.write(Data("Could not create the output canvas.\n".utf8))
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
context.interpolationQuality = .high
context.draw(
    sourceCGImage,
    in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize)
)

let pixelCount = outputSize * outputSize
var isBackground = Array(repeating: false, count: pixelCount)
var queue: [Int] = []
queue.reserveCapacity(pixelCount / 4)

func isNearBlack(_ index: Int) -> Bool {
    let offset = index * 4
    return max(pixelStorage[offset], pixelStorage[offset + 1], pixelStorage[offset + 2]) <= 18
}

func enqueueIfBackground(_ index: Int) {
    guard !isBackground[index], isNearBlack(index) else { return }
    isBackground[index] = true
    queue.append(index)
}

for coordinate in 0..<outputSize {
    enqueueIfBackground(coordinate)
    enqueueIfBackground((outputSize - 1) * outputSize + coordinate)
    enqueueIfBackground(coordinate * outputSize)
    enqueueIfBackground(coordinate * outputSize + outputSize - 1)
}

var queueIndex = 0
while queueIndex < queue.count {
    let index = queue[queueIndex]
    queueIndex += 1
    let x = index % outputSize
    let y = index / outputSize

    if x > 0 { enqueueIfBackground(index - 1) }
    if x + 1 < outputSize { enqueueIfBackground(index + 1) }
    if y > 0 { enqueueIfBackground(index - outputSize) }
    if y + 1 < outputSize { enqueueIfBackground(index + outputSize) }
}

for index in 0..<pixelCount where isBackground[index] {
    pixelStorage[index * 4 + 3] = 0
}

guard let outputCGImage = context.makeImage() else {
    FileHandle.standardError.write(Data("Could not finalize the processed image.\n".utf8))
    exit(1)
}

let bitmap = NSBitmapImageRep(cgImage: outputCGImage)
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the processed icon.\n".utf8))
    exit(1)
}

try pngData.write(to: outputURL, options: .atomic)
print("Wrote \(outputURL.path) from \(sourceCGImage.width)x\(sourceCGImage.height) artwork")
