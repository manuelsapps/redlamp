import CoreGraphics
import RedlampCanvas
import Testing
@testable import RedlampUI

/// Cropping fits the photo a little smaller, so its corner handles can't reach the toolbar, where
/// a drag moves the window, or the window's edges, where it resizes it.
struct CropStageTests {
    /// How far past the photo's corner a corner handle takes clicks: half of its 10 points, and 8 more.
    private static let handleReach: CGFloat = 13

    private static func stageInsets(cropping: Bool, panels: Bool = false, presenting: Bool = false) -> StageInsets {
        PanelMetrics.stageInsets(
            toolbarHeight: 52, presenting: presenting, leftPanel: panels, rightPanel: panels, filmstrip: nil,
            cropping: cropping,
        )
    }

    @Test func `the crop handles' click areas stop short of the toolbar and the window's edges`() {
        let insets = Self.stageInsets(cropping: true)
        #expect(insets.top - Self.handleReach > 52)
        #expect(insets.leading > Self.handleReach)
        #expect(insets.trailing > Self.handleReach)
        #expect(insets.bottom > Self.handleReach)
    }

    @Test func `cropping keeps the panels' width, moving only the gaps to the toolbar and the edges`() {
        let insets = Self.stageInsets(cropping: true, panels: true)
        let editing = Self.stageInsets(cropping: false, panels: true)
        let extra = PanelMetrics.cropClearance - PanelMetrics.inset
        #expect(insets.top == editing.top + PanelMetrics.cropClearance)
        #expect(insets.leading == editing.leading + extra)
        #expect(insets.trailing == editing.trailing + extra)
        #expect(insets.bottom == editing.bottom + extra)
    }

    @Test func `presenting still gives the photo the whole window`() {
        #expect(Self.stageInsets(cropping: true, presenting: true) == .zero)
    }
}
