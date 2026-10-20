import Foundation
import Testing
@testable import SweepCore
@testable import SweepUI

/// Sizing rules that keep screens from overflowing or squeezing text, checked at the window's
/// minimum (1040pt wide, 252pt of it sidebar) up to a large display.
@Suite struct LayoutTests {
    /// Detail area width at a given window width, minus the review screen's side padding.
    static func reviewWidth(window: CGFloat) -> CGFloat { window - 252 - 40 }

    @MainActor
    @Test func reviewItemColumnKeepsRoomAtMinimumWidth() {
        let total = Self.reviewWidth(window: 1040)
        let widths = CatalogReviewScreen.columnWidths(for: total)
        let items = total - widths.categories - widths.groups - 28
        #expect(items >= 240)
    }

    @MainActor
    @Test(arguments: [1040, 1280, 1440, 1680, 2560] as [CGFloat])
    func reviewColumnsStayInBounds(window: CGFloat) {
        let total = Self.reviewWidth(window: window)
        let widths = CatalogReviewScreen.columnWidths(for: total)
        #expect((196...260).contains(widths.categories))
        #expect((246...340).contains(widths.groups))
        #expect(total - widths.categories - widths.groups - 28 >= total * 0.3)
    }

    @MainActor
    @Test func checkupCardsFitAtMinimumWidth() {
        let available: CGFloat = 1040 - 252 - 60
        let width = CheckupView.cardWidth(for: available)
        let count = CGFloat(CheckupModel.modules.count)
        #expect(width * count + 14 * (count - 1) <= available)
        #expect(width >= 128)
    }

    @MainActor
    @Test func checkupCardsCapOnLargeWindows() {
        #expect(CheckupView.cardWidth(for: 2560 - 252 - 60) == 196)
    }

    @MainActor
    @Test func sidebarBadgesAreShort() {
        let state = AppState()
        for kind in [ModuleKind.cleanup, .protection, .performance, .applications, .declutter, .cloudFiles] {
            state.catalog(for: kind)?.load(DemoData.categories(for: kind))
        }
        // Sizes for modules that measure bytes, bare counts otherwise, never phrases like "2 updates".
        for kind in [ModuleKind.cleanup, .declutter, .cloudFiles] {
            let model = state.catalog(for: kind)!
            #expect(state.badge(for: kind) == ByteFormat.short(model.totalSize))
        }
        for kind in [ModuleKind.protection, .performance, .applications] {
            let badge = state.badge(for: kind)
            #expect(badge.map { Int($0) != nil } == true, "badge for \(kind) was \(badge ?? "nil")")
        }
    }
}
