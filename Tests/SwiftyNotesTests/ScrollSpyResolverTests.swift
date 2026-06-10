import Foundation
@testable import SwiftyNotes
import Testing

struct ScrollSpyResolverTests {
    @Test("Returns nil when there are no headings")
    func returnsNilWhenThereAreNoHeadings() {
        #expect(ScrollSpyResolver.activeHeadingID(positions: [], scrollTop: 0) == nil)
    }

    @Test("Single heading at the top is active as soon as the viewport opens")
    func singleHeadingAtTheTopIsActiveAsSoonAsTheViewport() {
        // y=0 means the heading sits at the very top of the document.
        // With scrollTop=0 and anchorOffset=80, anchor is at y=80, so the
        // heading is well above the anchor → active.
        let positions = [(id: "intro", y: 0.0)]
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 0) == "intro")
    }

    @Test("Returns nil when every heading is still below the anchor")
    func returnsNilWhenEveryHeadingIsStillBelowTheAnchor() {
        // First heading at y=200, scrollTop=0 → anchor is at y=80 → no
        // heading is at/above the anchor yet.
        let positions = [(id: "first", y: 200.0)]
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 0) == nil)
    }

    @Test("As user scrolls past a heading, that heading becomes active")
    func asUserScrollsPastAHeadingThatHeadingBecomesActive() {
        let positions = [
            (id: "h1", y: 0.0),
            (id: "h2", y: 500.0),
            (id: "h3", y: 1000.0),
        ]
        // Anchor (80) is past h1 but before h2 → h1 active.
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 0) == "h1")
        // Anchor at 500 — exactly at h2's y → h2 active.
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 420) == "h2")
        // Anchor between h2 and h3.
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 700) == "h2")
        // Anchor past h3.
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 1500) == "h3")
    }

    @Test("Ties at the same y favour the later heading in document order")
    func tiesAtTheSameYFavourTheLaterHeadingInDocumentOrder() {
        // Mirrors the JS "prefer the deepest (most recent) at the anchor"
        // behaviour: when two headings collide on y, the later one wins,
        // matching what the user visually sees as "the most recent
        // heading they passed".
        let positions = [
            (id: "first",  y: 100.0),
            (id: "second", y: 100.0),
        ]
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 100) == "second")
    }

    @Test("Custom anchor offset shifts the activation threshold")
    func customAnchorOffsetShiftsTheActivationThreshold() {
        // Anchor at scrollTop + 0 means the very first pixel into the
        // viewport activates a heading. Useful for headerless layouts.
        let positions = [(id: "h", y: 0.0), (id: "h2", y: 50.0)]
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 0, anchorOffset: 0) == "h")
        #expect(ScrollSpyResolver.activeHeadingID(positions: positions, scrollTop: 50, anchorOffset: 0) == "h2")
    }
}
