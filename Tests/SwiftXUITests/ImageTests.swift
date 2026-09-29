import Testing
@testable import SwiftXUI

private func renderedImages(_ view: some XView, canvas: Size = Size(width: 300, height: 200)) -> [RecordingCanvas.RecordedImage] {
    let surface = RecordingCanvas()
    LayoutHost(canvas: canvas).render(view, into: surface)
    return surface.images
}

@Test func imageReportsNaturalSizeUntilResizable() {
    let source = ImageSource("hero", naturalSize: Size(width: 96, height: 48))
    let images = renderedImages(Image(source))

    #expect(images.count == 1)
    #expect(images[0].source == source)
    #expect(images[0].rect.isApproximately(Rect(x: 0, y: 0, width: 96, height: 48)))
}

@Test func resizableImageAcceptsOfferedFrame() {
    let source = ImageSource("hero", naturalSize: Size(width: 96, height: 48))
    let images = renderedImages(
        Image(source)
            .resizable()
            .frame(width: 140, height: 90)
    )

    #expect(images[0].rect.isApproximately(Rect(x: 0, y: 0, width: 140, height: 90)))
}

@Test func resizableImageWorksWithScaledToFit() {
    let source = ImageSource("hero", naturalSize: Size(width: 160, height: 80))
    let images = renderedImages(
        Image(source)
            .resizable()
            .scaledToFit()
            .frame(width: 100, height: 100)
    )

    #expect(images[0].rect.isApproximately(Rect(x: 0, y: 25, width: 100, height: 50)))
}

@Test func imageOpacityIsRecorded() {
    let source = ImageSource("hero", naturalSize: Size(width: 96, height: 48))
    let images = renderedImages(Image(source).opacity(0.5))

    #expect(images[0].opacity == 0.5)
}
