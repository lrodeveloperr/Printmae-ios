import XCTest
@testable import PrintMaeEngine

final class RecipeAndRatingTests: XCTestCase {
    func testTenThousandUndoRedoSequencesRoundTripExactly() {
        let history = RecipeHistory()
        for index in 0 ..< 10_000 {
            var snapshot = PrintJobSnapshot.new()
            let original = snapshot.editRecipe
            let actionCount = (index % 7) + 1
            for actionIndex in 0 ..< actionCount {
                snapshot = history.apply(
                    .rotate(
                        pageIndexes: IndexSet(integer: (index + actionIndex) % 11),
                        quarterTurnsClockwise: (index + actionIndex) % 4
                    ),
                    to: snapshot
                )
            }
            let final = snapshot.editRecipe
            for _ in 0 ..< actionCount { snapshot = history.undo(snapshot) }
            XCTAssertEqual(snapshot.editRecipe, original)
            for _ in 0 ..< actionCount { snapshot = history.redo(snapshot) }
            XCTAssertEqual(snapshot.editRecipe, final)
        }
    }

    func testApplyingAfterUndoDiscardsTheRedoStack() {
        let history = RecipeHistory()
        var snapshot = PrintJobSnapshot.new()
        snapshot = history.apply(.rotate(pageIndexes: IndexSet(integer: 0), quarterTurnsClockwise: 1), to: snapshot)
        snapshot = history.apply(.rotate(pageIndexes: IndexSet(integer: 1), quarterTurnsClockwise: 2), to: snapshot)
        snapshot = history.undo(snapshot)
        XCTAssertEqual(snapshot.redoRecipes.count, 1)

        // A fresh edit after an undo must invalidate the redo stack, not leave the old future
        // sitting there to be replayed by a later redo.
        snapshot = history.apply(.rotate(pageIndexes: IndexSet(integer: 2), quarterTurnsClockwise: 3), to: snapshot)
        XCTAssertTrue(snapshot.redoRecipes.isEmpty)
    }

    func testRedoPushesTheCurrentRecipeBackOntoUndo() {
        let history = RecipeHistory()
        var snapshot = PrintJobSnapshot.new()
        snapshot = history.apply(.rotate(pageIndexes: IndexSet(integer: 0), quarterTurnsClockwise: 1), to: snapshot)
        let afterFirstFix = snapshot.editRecipe
        snapshot = history.apply(.rotate(pageIndexes: IndexSet(integer: 1), quarterTurnsClockwise: 2), to: snapshot)
        snapshot = history.undo(snapshot)
        XCTAssertEqual(snapshot.editRecipe, afterFirstFix)

        snapshot = history.redo(snapshot)
        // Undoing again after the redo must be able to step back to exactly the pre-redo
        // recipe, which only works if redo pushed it onto the undo stack.
        snapshot = history.undo(snapshot)
        XCTAssertEqual(snapshot.editRecipe, afterFirstFix)
    }

    func testCompressionPolicyNeverDropsBelow150DPI() {
        XCTAssertTrue(CompressionPolicy().isValid)
        XCTAssertFalse(CompressionPolicy(rasterDPI: 149, minimumRasterDPI: 149).isValid)
        XCTAssertFalse(CompressionPolicy(jpegQualitySteps: [0.8, -0.1]).isValid)
    }

    func testRatingPromptOnlyOnEligibleThirdSuccess() {
        let install = Date(timeIntervalSince1970: 1_700_000_000)
        let eligible = RatingPromptContext(
            completedJobOrdinal: 3,
            installationDate: install,
            now: install.addingTimeInterval(8 * 86_400),
            lastPromptDate: nil,
            jobHadError: false,
            paywallWasJustDismissed: false
        )
        XCTAssertTrue(RatingPromptPolicy.shouldRequest(eligible))
        XCTAssertFalse(RatingPromptPolicy.shouldRequest(
            RatingPromptContext(
                completedJobOrdinal: 3,
                installationDate: install,
                now: eligible.now,
                lastPromptDate: nil,
                jobHadError: true,
                paywallWasJustDismissed: false
            )
        ))
        XCTAssertTrue(RatingPromptPolicy.shouldRequest(
            RatingPromptContext(
                completedJobOrdinal: 4,
                installationDate: install,
                now: eligible.now,
                lastPromptDate: nil,
                jobHadError: false,
                paywallWasJustDismissed: false
            )
        ))
        XCTAssertFalse(RatingPromptPolicy.shouldRequest(
            RatingPromptContext(
                completedJobOrdinal: 2,
                installationDate: install,
                now: eligible.now,
                lastPromptDate: nil,
                jobHadError: false,
                paywallWasJustDismissed: false
            )
        ))
    }
}
