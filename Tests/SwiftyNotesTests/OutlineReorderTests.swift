import Foundation
@testable import SwiftyNotes
import Testing

struct OutlineReorderTests {
    @Test("Moves an H2 section before another, taking its H3 children with it")
    func movesAnH2SectionBeforeAnotherTakingItsH3ChildrenWithIt() {
        let markdown = """
        # Doc

        ## A

        A body.

        ### A1

        A1 body.

        ## B

        B body.
        """
        let headings: [Heading] = [
            .init(id: "doc", level: 1, text: "Doc",   blockIndex: 0, line: 1),
            .init(id: "a",   level: 2, text: "A",     blockIndex: 1, line: 3),
            .init(id: "a1",  level: 3, text: "A1",    blockIndex: 2, line: 7),
            .init(id: "b",   level: 2, text: "B",     blockIndex: 3, line: 11),
        ]
        let moved = OutlineReorder.movedMarkdown(
            markdown,
            movingID: "b",
            beforeTargetID: "a",
            headings: headings,
        )
        // After the move, the blank line that originally separated A1
        // from B becomes a trailing newline at the end of the file —
        // the move doesn't try to renormalize blank-line spacing
        // around the cut point. Rendered markdown is unaffected.
        let expected = """
        # Doc

        ## B

        B body.
        ## A

        A body.

        ### A1

        A1 body.

        """
        #expect(moved == expected)
    }

    @Test("Dropping a section on itself is a no-op")
    func droppingASectionOnItselfIsANoOp() {
        let markdown = "## A\nA body."
        let headings: [Heading] = [
            .init(id: "a", level: 2, text: "A", blockIndex: 0, line: 1),
        ]
        #expect(OutlineReorder.movedMarkdown(markdown, movingID: "a", beforeTargetID: "a", headings: headings) == nil)
    }

    @Test("Rejects dropping a section onto a heading inside its own subtree")
    func rejectsDroppingASectionOntoAHeadingInsideItsOwnSubtree() {
        // Moving the H2 "A" "before" its own child "A1" would try to
        // insert A's section in the middle of itself. Reject.
        let markdown = """
        ## A
        ### A1
        body
        ## B
        """
        let headings: [Heading] = [
            .init(id: "a",  level: 2, text: "A",  blockIndex: 0, line: 1),
            .init(id: "a1", level: 3, text: "A1", blockIndex: 1, line: 2),
            .init(id: "b",  level: 2, text: "B",  blockIndex: 2, line: 4),
        ]
        #expect(OutlineReorder.movedMarkdown(markdown, movingID: "a", beforeTargetID: "a1", headings: headings) == nil)
    }

    @Test("Dropping on an unknown id returns nil")
    func droppingOnAnUnknownIdReturnsNil() {
        let markdown = "## A\n## B"
        let headings: [Heading] = [
            .init(id: "a", level: 2, text: "A", blockIndex: 0, line: 1),
            .init(id: "b", level: 2, text: "B", blockIndex: 1, line: 2),
        ]
        #expect(OutlineReorder.movedMarkdown(markdown, movingID: "ghost", beforeTargetID: "a", headings: headings) == nil)
        #expect(OutlineReorder.movedMarkdown(markdown, movingID: "a", beforeTargetID: "ghost", headings: headings) == nil)
    }

    @Test("Moves an H3 within its parent H2, leaving sibling H3s in place")
    func movesAnH3WithinItsParentH2LeavingSiblingH3sInPlace() {
        let markdown = """
        ## A
        ### A1
        a1 body
        ### A2
        a2 body
        ### A3
        a3 body
        """
        let headings: [Heading] = [
            .init(id: "a",  level: 2, text: "A",  blockIndex: 0, line: 1),
            .init(id: "a1", level: 3, text: "A1", blockIndex: 1, line: 2),
            .init(id: "a2", level: 3, text: "A2", blockIndex: 2, line: 4),
            .init(id: "a3", level: 3, text: "A3", blockIndex: 3, line: 6),
        ]
        // Move A3 above A1.
        let moved = OutlineReorder.movedMarkdown(
            markdown,
            movingID: "a3",
            beforeTargetID: "a1",
            headings: headings,
        )
        let expected = """
        ## A
        ### A3
        a3 body
        ### A1
        a1 body
        ### A2
        a2 body
        """
        #expect(moved == expected)
    }

    @Test("Moving the last H2 to the front handles EOF correctly")
    func movingTheLastH2ToTheFrontHandlesEOFCorrectly() {
        let markdown = """
        ## A
        a body
        ## B
        b body
        """
        let headings: [Heading] = [
            .init(id: "a", level: 2, text: "A", blockIndex: 0, line: 1),
            .init(id: "b", level: 2, text: "B", blockIndex: 1, line: 3),
        ]
        let moved = OutlineReorder.movedMarkdown(
            markdown,
            movingID: "b",
            beforeTargetID: "a",
            headings: headings,
        )
        let expected = """
        ## B
        b body
        ## A
        a body
        """
        #expect(moved == expected)
    }
}
