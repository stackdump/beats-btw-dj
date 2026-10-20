#!/usr/bin/env swift
// Draws the placeholder app icon (a vinyl on a deck, with a Petri-net label) to a 1024x1024 PNG.
// usage: swift scripts/make-icon.swift [out.png]   (default assets/AppIcon.png; `make icon`)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.png"
let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
  CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient {
  CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
}

// macOS icon grid: an 824-point body centred in the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0.1, 0.1, 0.16))
ctx.fillPath()
ctx.restoreGState()

// Deck plate: dark indigo diagonal gradient.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(
  gradient([rgb(0.20, 0.17, 0.36), rgb(0.07, 0.06, 0.14)]),
  start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

let c = CGPoint(x: 512, y: 512)

// Vinyl: black disc with a faint sheen, then grooves.
let vinylR: CGFloat = 345
ctx.setFillColor(rgb(0.04, 0.04, 0.06))
ctx.fillEllipse(
  in: CGRect(x: c.x - vinylR, y: c.y - vinylR, width: vinylR * 2, height: vinylR * 2))
ctx.setLineWidth(2)
var r: CGFloat = 175
var i = 0
while r < vinylR - 8 {
  ctx.setStrokeColor(rgb(1, 1, 1, i % 3 == 0 ? 0.10 : 0.05))
  ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
  r += 11
  i += 1
}
// Two opposed sheen wedges (conic highlight look).
for angle in [CGFloat.pi * 0.25, CGFloat.pi * 1.25] {
  ctx.saveGState()
  ctx.beginPath()
  ctx.move(to: c)
  ctx.addArc(
    center: c, radius: vinylR - 4, startAngle: angle - 0.28, endAngle: angle + 0.28, clockwise: false)
  ctx.closePath()
  ctx.clip()
  ctx.drawRadialGradient(
    gradient([rgb(1, 1, 1, 0.0), rgb(1, 1, 1, 0.16)]), startCenter: c, startRadius: 120,
    endCenter: c, endRadius: vinylR, options: [])
  ctx.restoreGState()
}
ctx.setStrokeColor(rgb(1, 1, 1, 0.18))
ctx.setLineWidth(3)
ctx.strokeEllipse(in: CGRect(x: c.x - vinylR, y: c.y - vinylR, width: vinylR * 2, height: vinylR * 2))

// Label: magenta-to-amber disc carrying a Petri net (place – transition – place).
let labelR: CGFloat = 150
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - labelR, y: c.y - labelR, width: labelR * 2, height: labelR * 2))
ctx.clip()
ctx.drawLinearGradient(
  gradient([rgb(1.0, 0.30, 0.55), rgb(1.0, 0.70, 0.25)]),
  start: CGPoint(x: c.x - labelR, y: c.y + labelR), end: CGPoint(x: c.x + labelR, y: c.y - labelR),
  options: [])
ctx.restoreGState()

let ink = rgb(0.10, 0.07, 0.16)
ctx.setStrokeColor(ink)
ctx.setFillColor(ink)
ctx.setLineWidth(9)
let px: CGFloat = 78  // place centre offset
let pr: CGFloat = 27  // place radius
for dx in [-px, px] {
  ctx.strokeEllipse(in: CGRect(x: c.x + dx - pr, y: c.y - pr, width: pr * 2, height: pr * 2))
}
ctx.fill(CGRect(x: c.x - 9, y: c.y - 38, width: 18, height: 76))  // the transition bar
for dir: CGFloat in [-1, 1] {  // arcs: place -> bar -> place
  ctx.move(to: CGPoint(x: c.x + dir * (px - pr), y: c.y))
  ctx.addLine(to: CGPoint(x: c.x + dir * 9, y: c.y))
  ctx.strokePath()
}
ctx.fillEllipse(in: CGRect(x: c.x - px - 9, y: c.y - 9, width: 18, height: 18))  // a token
// Spindle hole.
ctx.setFillColor(rgb(0.07, 0.06, 0.14))
ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))

// Tonearm: pivot top right, arm sweeping to a headshell on the record.
let pivot = CGPoint(x: 790, y: 800)
let elbow = CGPoint(x: 790, y: 560)
let tip = CGPoint(x: 640, y: 420)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: rgb(0, 0, 0, 0.5))
ctx.setStrokeColor(rgb(0.86, 0.87, 0.92))
ctx.setLineWidth(15)
ctx.move(to: pivot)
ctx.addLine(to: elbow)
ctx.addLine(to: tip)
ctx.strokePath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(rgb(0.86, 0.87, 0.92))
ctx.fillEllipse(in: CGRect(x: pivot.x - 46, y: pivot.y - 46, width: 92, height: 92))
ctx.setFillColor(rgb(0.30, 0.28, 0.45))
ctx.fillEllipse(in: CGRect(x: pivot.x - 22, y: pivot.y - 22, width: 44, height: 44))
// Headshell.
ctx.saveGState()
ctx.translateBy(x: tip.x, y: tip.y)
ctx.rotate(by: -.pi * 0.75)
ctx.setFillColor(rgb(1.0, 0.70, 0.25))
ctx.addPath(CGPath(roundedRect: CGRect(x: -16, y: -34, width: 32, height: 68), cornerWidth: 8, cornerHeight: 8, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// Top edge highlight.
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.14))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage(),
  let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot write \(out)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG encode failed") }
print(out)
