import Testing
@testable import XUI

private let shapes: [(String, Size)] = [
    ("phone portrait", Size(width: 390, height: 844)),
    ("phone landscape", Size(width: 844, height: 390)),
    ("tablet landscape", Size(width: 1194, height: 834)),
    ("square", Size(width: 600, height: 600)),
    ("ultrawide", Size(width: 1920, height: 540)),
]

@Test(arguments: shapes)
func theKeyboardFitsEveryShapeWithoutSwallowingTheScreen(shape: (String, Size)) {
    let metrics = KeyboardMetrics.compute(container: shape.1, rowCount: 4)
    #expect(metrics.height <= shape.1.height * 0.5, "\(shape.0)")
    #expect(metrics.rect.maxY == shape.1.height)
    #expect(metrics.rect.x >= 0 && metrics.rect.maxX <= shape.1.width + 0.001)
    #expect(metrics.keyHeight >= 10)
    // Wide boxes keep finger-shaped keys instead of stretching edge to edge.
    #expect(metrics.rect.width <= shape.1.height * 1.55 + 0.001)
}

@Test
func aTallBoxUsesTheFullWidthAndAWideBoxCentresTheKeyboard() {
    let tall = KeyboardMetrics.compute(container: Size(width: 390, height: 844), rowCount: 4)
    #expect(tall.rect.width == 390 && tall.rect.x == 0)
    let wide = KeyboardMetrics.compute(container: Size(width: 1920, height: 540), rowCount: 4)
    #expect(wide.rect.width < 1920)
    #expect(abs(wide.rect.midX - 960) < 0.001)
}

@Test
func everyLetterPageHasTheAlphabetOnce() {
    for shift in [ShiftState.off, .once, .capsLock] {
        let rows = KeyboardLayout.rows(page: .letters, shift: shift, returnKey: .done)
        let letters = rows.flatMap { $0 }.compactMap { key -> String? in
            if case .character(let c) = key.action { return c }
            return nil
        }.filter { !$0.isEmpty }
        let expected = shift == .off ? "abcdefghijklmnopqrstuvwxyz" : "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        #expect(letters.sorted() == expected.map(String.init).sorted())
    }
}

@Test
func everyPageOffersBackspaceAndReturnWithTheFieldsLabel() {
    for page in [KeyboardPage.letters, .numbers, .symbols, .numberPad] {
        let keys = KeyboardLayout.rows(page: page, shift: .off, returnKey: .search).flatMap { $0 }
        #expect(keys.contains { $0.action == .backspace }, "\(page)")
        #expect(keys.contains { $0.action == .returnKey && $0.label == "Search" }, "\(page)")
    }
}

@Test
func theNumberPadStartsNumberFieldsAndLettersStartTextFields() {
    #expect(KeyboardLayout.firstPage(for: .number) == .numberPad)
    #expect(KeyboardLayout.firstPage(for: .text) == .letters)
    let digits = KeyboardLayout.rows(page: .numberPad, shift: .off, returnKey: .done).flatMap { $0 }
    #expect(digits.filter { if case .character(let c) = $0.action { return c.first?.isNumber == true } else { return false } }.count == 10)
}

@Test
func touchesInTheGapsAndMarginsStillFindTheNearestKey() {
    let metrics = KeyboardMetrics.compute(container: Size(width: 390, height: 844), rowCount: 4)
    let rows = KeyboardLayout.rows(page: .letters, shift: .off, returnKey: .done)
    let placed = metrics.place(rows, in: metrics.rect)
    let q = placed.first { $0.key.label == "q" }!
    let w = placed.first { $0.key.label == "w" }!
    // Exactly between Q and W (in the gap) resolves to one of them, never nothing.
    let gap = Point(x: (q.rect.maxX + w.rect.x) / 2, y: q.rect.midY)
    let hit = metrics.key(at: gap, in: placed, rect: metrics.rect)
    #expect(hit?.key.label == "q" || hit?.key.label == "w")
    // Between rows too.
    let between = Point(x: q.rect.midX, y: q.rect.maxY + metrics.gap / 2)
    #expect(metrics.key(at: between, in: placed, rect: metrics.rect) != nil)
    // The home row's half-key margins belong to the neighbouring letter, not to a blank cell.
    let a = placed.first { $0.key.label == "a" }!
    let margin = Point(x: metrics.rect.x + 2, y: a.rect.midY)
    #expect(metrics.key(at: margin, in: placed, rect: metrics.rect)?.key.label == "a")
    // Far outside is nothing.
    #expect(metrics.key(at: Point(x: -100, y: 0), in: placed, rect: metrics.rect) == nil)
}

@Test
func keysTileEachRowWithoutOverlap() {
    let metrics = KeyboardMetrics.compute(container: Size(width: 600, height: 500), rowCount: 4)
    for page in [KeyboardPage.letters, .numbers, .symbols, .numberPad] {
        let placed = metrics.place(KeyboardLayout.rows(page: page, shift: .off, returnKey: .done), in: metrics.rect)
        for row in Set(placed.map(\.row)) {
            let keys = placed.filter { $0.row == row }.sorted { $0.rect.x < $1.rect.x }
            for (a, b) in zip(keys, keys.dropFirst()) { #expect(a.rect.maxX <= b.rect.x + 0.001) }
            #expect(keys.first!.rect.x >= metrics.rect.x && keys.last!.rect.maxX <= metrics.rect.maxX + 0.001)
        }
    }
}
