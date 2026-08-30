import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAutomation

struct PeekabooAIServiceImageMIMETests {
    @Test
    func `Analyze image MIME uses jpeg for jpg and jpeg paths`() {
        #expect(PeekabooAIService.imageMIMEType(forPath: "/tmp/shot.jpg") == "image/jpeg")
        #expect(PeekabooAIService.imageMIMEType(forPath: "/tmp/shot.jpeg") == "image/jpeg")
        #expect(PeekabooAIService.imageMIMEType(forPath: "/tmp/shot.JPG") == "image/jpeg")
    }

    @Test
    func `Analyze image MIME uses webp and png from the path extension`() {
        #expect(PeekabooAIService.imageMIMEType(forPath: "/tmp/shot.webp") == "image/webp")
        #expect(PeekabooAIService.imageMIMEType(forPath: "/tmp/shot.png") == "image/png")
    }

    @Test
    func `Analyze image MIME uses ImageIO for jpeg bytes without a path`() throws {
        let jpegData = try Self.makePixelImage(uti: .jpeg)
        #expect(PeekabooAIService.imageMIMEType(forImageData: jpegData) == "image/jpeg")
    }

    @Test
    func `Analyze image content labels jpeg files as image/jpeg`() throws {
        let jpegData = try Self.makePixelImage(uti: .jpeg)
        let content = PeekabooAIService.analyzeImageContent(imageData: jpegData, path: "/tmp/photo.jpg")
        #expect(content.mimeType == "image/jpeg")
        #expect(content.data == jpegData.base64EncodedString())
    }

    @Test
    func `Analyze image content labels webp paths as image/webp`() {
        let content = PeekabooAIService.analyzeImageContent(imageData: Data([0x00]), path: "/tmp/photo.webp")
        #expect(content.mimeType == "image/webp")
    }

    private static func makePixelImage(uti: UTType) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels: [UInt8] = [255, 0, 0, 255]
        guard let context = CGContext(
            data: &pixels,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage()
        else {
            throw MIMETestError.couldNotCreatePixel
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            uti.identifier as CFString,
            1,
            nil)
        else {
            throw MIMETestError.couldNotCreateDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MIMETestError.couldNotFinalize
        }
        return output as Data
    }
}

private enum MIMETestError: Error {
    case couldNotCreatePixel
    case couldNotCreateDestination
    case couldNotFinalize
}
