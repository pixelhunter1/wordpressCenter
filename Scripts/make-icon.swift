// Gera o ícone da app (PNG 1024×1024) a partir do logo. Uso: swift Scripts/make-icon.swift Assets/logo.svg saida.png
// Segue a grelha de ícones do macOS: forma arredondada de 824 pt centrada numa tela de 1024, com sombra.
import AppKit

let logo = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // O símbolo ocupa ~47% da largura do SVG (fundo branco à volta). Para ficar com ~60% do corpo do ícone,
    // o SVG é desenhado a ~129% do corpo e recortado pela forma arredondada.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    let side = rect.width * 1.29
    logo.draw(in: NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side))
    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.08).setStroke() // contorno subtil, visível em fundos claros
    shape.lineWidth = 2
    shape.stroke()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
