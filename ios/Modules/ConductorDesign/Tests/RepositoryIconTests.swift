//
//  RepositoryIconTests.swift
//  ConductorDesignTests
//
//  Created by Gannon Prudomme on 7/20/26.
//

@testable import ConductorDesign
import Testing
import UIKit

struct RepositoryIconTests {
    @MainActor
    @Test("Remote icons keep Retina sizing and rounded corners")
    func remoteIconScale() async throws {
        for sourceScale in [CGFloat(1), CGFloat(3)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = sourceScale
            let sourceImage = UIGraphicsImageRenderer(
                size: CGSize(width: 120, height: 120),
                format: format
            ).image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            }

            let image = try #require(
                await RepositoryIcon.prepareRemoteImage(
                    sourceImage,
                    size: 20,
                    displayScale: 3
                )
            )

            #expect(image.size == CGSize(width: 20, height: 20))
            #expect(image.scale == 3)
            #expect(image.cgImage?.width == 60)
            #expect(image.cgImage?.height == 60)
            #expect(alpha(in: image, x: 0, y: 0) == 0)
            #expect(alpha(in: image, x: 30, y: 30) == 255)
        }
    }
}

@MainActor
private func alpha(in image: UIImage, x: Int, y: Int) -> UInt8? {
    guard let cgImage = image.cgImage else {
        return nil
    }
    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let didRender = pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard didRender else {
        return nil
    }
    return pixels[(y * width + x) * 4 + 3]
}
