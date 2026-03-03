#!/usr/bin/env swift
import AppKit

// Generate Engram app icon using SF Symbols
let symbolName = "brain.head.profile"
let sizes = [16, 32, 128, 256, 512]

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
    print("Failed to load symbol: \(symbolName)")
    exit(1)
}

for size in sizes {
    for scale in [1, 2] {
        let pixelSize = size * scale
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(pixelSize) * 0.7, weight: .regular)
        let configuredSymbol = symbol.withSymbolConfiguration(config)!

        let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let image = NSImage(size: rect.size)

        image.lockFocus()

        // Draw gradient background
        let context = NSGraphicsContext.current!
        let cgContext = context.cgContext

        let colorspace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0),  // Deep blue
            CGColor(red: 0.4, green: 0.2, blue: 0.6, alpha: 1.0)   // Purple
        ] as CFArray

        guard let gradient = CGGradient(colorsSpace: colorspace, colors: colors, locations: [0, 1]) else {
            print("Failed to create gradient")
            exit(1)
        }

        let center = CGPoint(x: pixelSize / 2, y: pixelSize / 2)
        let radius = CGFloat(pixelSize) / 2
        cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])

        // Draw symbol
        let symbolSize = configuredSymbol.size
        let symbolRect = NSRect(
            x: (CGFloat(pixelSize) - symbolSize.width) / 2,
            y: (CGFloat(pixelSize) - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )

        configuredSymbol.draw(in: symbolRect)

        image.unlockFocus()

        // Save to file
        let filename = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let path = "\(outputDir)/\(filename)"

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("Failed to create PNG data")
            exit(1)
        }

        try! pngData.write(to: URL(fileURLWithPath: path))
        print("Generated: \(filename)")
    }
}

print("Done!")
