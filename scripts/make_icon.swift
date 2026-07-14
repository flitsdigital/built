// Genereert het app-icoon: groene gradient + witte dumbbell.
// Gebruik: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let colors = [
    NSColor(calibratedRed: 0.13, green: 0.72, blue: 0.39, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.02, green: 0.32, blue: 0.20, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

let config = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold)
let symbol = NSImage(systemSymbolName: "dumbbell.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!

let tinted = NSImage(size: symbol.size)
tinted.lockFocus()
symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.set()
NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
tinted.unlockFocus()

let symbolRect = NSRect(x: (size - symbol.size.width) / 2,
                        y: (size - symbol.size.height) / 2,
                        width: symbol.size.width,
                        height: symbol.size.height)
tinted.draw(in: symbolRect)

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
rep.size = NSSize(width: size, height: size)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("Icon geschreven naar \(out) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
