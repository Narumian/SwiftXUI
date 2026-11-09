import Foundation
import Testing
import XUI
import XWorkspace
@testable import XWorkspaceUI

private let folder = UUID()

private func item(_ name: String, directory: Bool = false) -> BrowserItem {
    BrowserItem(entry: WorkspaceEntry(folderID: folder, path: name, kind: directory ? .directory : .file))
}

@Test
func foldersSortBeforeFilesAndNumbersCompareByValue() {
    let items = ["clip10.png", "Clip2.png", "b", "a", "clip1.png"].map { item($0, directory: $0.count == 1) }
    let names = BrowserOrdering.sorted(items).map(\.name)
    #expect(names == ["a", "b", "clip1.png", "Clip2.png", "clip10.png"])
}

@Test
func leadingZerosDoNotChangeTheValueOrder() {
    let names = BrowserOrdering.sorted(["f007", "f7", "f10", "f9"].map { item($0) }).map(\.name)
    #expect(names.first == "f007" || names.first == "f7")
    #expect(Array(names.suffix(2)) == ["f9", "f10"])
}

@Test
func fastOrderAgreesWithTheFoundationOrderOnTypicalNames() {
    let names = (0..<300).map { "Take \($0 * 7 % 113) - shot\($0 % 17).mov" } + ["alpha", "Beta", "gamma", "delta2", "delta10"]
    let items = names.map { item($0) }
    #expect(BrowserOrdering.sorted(items).map(\.name) == BrowserOrdering.referenceSorted(items).map(\.name))
}

@Test
func queryFiltersWithoutResorting() {
    let items = BrowserOrdering.sorted(["Cat.png", "dog.png", "concat.txt", "bird.jpg"].map { item($0) })
    let hits = BrowserOrdering.visible(in: items, filter: .all, query: "CAT").map { items[Int($0)].name }
    #expect(hits == ["Cat.png", "concat.txt"])
    #expect(BrowserOrdering.visible(in: items, filter: .all, query: "").count == 4)
    #expect(BrowserOrdering.visible(in: items, filter: .all, query: "zzz").isEmpty)
}

@Test
func filtersKeepDirectoriesAndMatchCategoriesOrExtensions() {
    let items = BrowserOrdering.sorted([item("sub", directory: true), item("a.png"), item("b.mov"), item("c.ild")])
    let images = BrowserOrdering.visible(in: items, filter: BrowserFilter(categories: [.image]), query: "").map { items[Int($0)].name }
    #expect(images == ["sub", "a.png"])
    let laser = BrowserOrdering.visible(in: items, filter: BrowserFilter(extensions: ["ild"]), query: "").map { items[Int($0)].name }
    #expect(laser == ["sub", "c.ild"])
}

@Test
func categoriesComeFromTheExtension() {
    #expect(item("x.PNG").category == .image)
    #expect(item("x.fs").category == .shader)
    #expect(item("x.ild").category == .laser)
    #expect(item("noext").category == .other)
    #expect(item("sub", directory: true).category == .folder)
}

@Test func aHostCanAddCategoriesWithTheirOwnExtensionsAndColors() {
    let custom = FileCategory(rawValue: FileCategory.firstCustom)
    let color = XColorValue(hex: 0x123456)
    let types = FileTypes.standard.adding(custom, color: color, extensions: ["geometry", "fs"])
    func item(_ name: String, _ types: FileTypes) -> BrowserItem {
        BrowserItem(entry: WorkspaceEntry(folderID: UUID(), path: name, kind: .file), types: types)
    }
    #expect(item("circle.geometry", types).category == custom)
    #expect(types.color(for: custom) == color)
    // An extension given by the host wins over a built-in one; the others are untouched.
    #expect(item("x.fs", types).category == custom)
    #expect(item("x.fs", .standard).category == .shader)
    #expect(item("x.png", types).category == .image)
    // Without the host's types, the extension is just an unknown file.
    #expect(item("circle.geometry", .standard).category == .other)
    // A category the host gave no colour falls back to the neutral one.
    #expect(FileTypes.standard.color(for: custom) == FileTypes.standard.color(for: .other))
}
