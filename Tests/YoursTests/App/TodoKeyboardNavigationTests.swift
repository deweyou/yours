import Foundation
import Testing

@testable import Yours

struct TodoKeyboardNavigationTests {
    @Test func navigationClampsAtEndsAndStartsFromTheRequestedEdge() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(TodoKeyboardNavigation.adjacentID(in: ids, current: nil, offset: 1) == ids[0])
        #expect(TodoKeyboardNavigation.adjacentID(in: ids, current: nil, offset: -1) == ids[2])
        #expect(TodoKeyboardNavigation.adjacentID(in: ids, current: ids[0], offset: -1) == ids[0])
        #expect(TodoKeyboardNavigation.adjacentID(in: ids, current: ids[2], offset: 1) == ids[2])
        #expect(TodoKeyboardNavigation.adjacentID(in: ids, current: ids[1], offset: 1) == ids[2])
        #expect(TodoKeyboardNavigation.adjacentID(in: ids, current: ids[1], offset: -1) == ids[0])
    }

    @Test func disappearingFocusUsesTheCurrentVisibleRows() {
        let removed = UUID()
        let visible = [UUID(), UUID()]
        #expect(TodoKeyboardNavigation.adjacentID(in: visible, current: removed, offset: 1) == visible[0])
        #expect(TodoKeyboardNavigation.adjacentID(in: visible, current: removed, offset: -1) == visible[1])
        #expect(TodoKeyboardNavigation.adjacentID(in: [], current: removed, offset: 1) == nil)
    }
}
