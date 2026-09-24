import SwiftUI

struct NotchSurfaceContainerView: View {
    @ObservedObject var notchViewModel: NotchViewModel
    
    var body: some View {
        notchSurface
            .overlay {
                contentOverlayWrapped
            }
    }
    
    @ViewBuilder
    private var notchSurface: some View {
        let isDynamicIsland = notchViewModel.isDynamicIsland
        
        NotchBackgroundSurface(
            topCornerRadius: notchViewModel.interactiveCornerRadius.top,
            bottomCornerRadius: notchViewModel.interactiveCornerRadius.bottom,
            isDynamicIsland: isDynamicIsland,
            dynamicIslandCornerRadius: notchViewModel.dynamicIslandCornerRadius
        )
        .scaleEffect(
            x: shouldApplyPressScale ? notchViewModel.pressScale : 1,
            y: shouldApplyPressScale ? notchViewModel.pressScale : 1,
            anchor: .top
        )
    }
    
    @ViewBuilder
    private var contentOverlayWrapped: some View {
        if notchViewModel.isDynamicIsland {
            contentOverlay
                .environment(\.isDynamicIsland, true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask {
                    DynamicIslandShape(
                        cornerRadius: max(0, notchViewModel.dynamicIslandCornerRadius - 2)
                    )
                    .padding(3)
                    .scaleEffect(
                        x: shouldApplyPressScale ? notchViewModel.pressScale : 1,
                        y: shouldApplyPressScale ? notchViewModel.pressScale : 1,
                        anchor: .top
                    )
                }
        } else {
            contentOverlay
                .environment(\.isDynamicIsland, false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask {
                    NotchShape(
                        topCornerRadius: max(0, notchViewModel.interactiveCornerRadius.top - 2),
                        bottomCornerRadius: max(0, notchViewModel.interactiveCornerRadius.bottom - 2)
                    )
                    .padding(.horizontal, 5)
                    .padding(.bottom, 3)
                    .scaleEffect(
                        x: shouldApplyPressScale ? notchViewModel.pressScale : 1,
                        y: shouldApplyPressScale ? notchViewModel.pressScale : 1,
                        anchor: .top
                    )
                }
        }
    }
    
    @ViewBuilder
    private var contentOverlay: some View {
        if let content = notchViewModel.displayedContent {
            renderedContentView(for: content)
                .scaleEffect(
                    x: shouldApplyPressScale ? notchViewModel.pressScale : 1,
                    y: shouldApplyPressScale ? notchViewModel.pressScale : 1,
                    anchor: .top
                )
                .resizeAwareBlur(
                    size: notchViewModel.interactiveNotchSize,
                    baseHeight: notchViewModel.notchModel.baseHeight,
                    isResizeEffectEnabled: content.usesContentResizeEffect,
                    interactiveBlur: notchViewModel.contentResizeBlurRadius,
                    interactiveOpacity: notchViewModel.contentResizeOpacity,
                    swipeProgress: notchViewModel.easedSwipeStretchProgress,
                    swipeInteraction: notchViewModel.swipeInteraction
                )
                .id(notchViewModel.displayedPresentationID)
                .transition(
                    notchViewModel.contentTransition(
                        notchHeight: notchViewModel.presentedNotchSize.height,
                        baseHeight: notchViewModel.notchModel.baseHeight,
                        isExpandedPresentation: notchViewModel.isDisplayingExpandedLiveActivity
                    )
                )
        }
    }
    
    @MainActor
    @ViewBuilder
    private func renderedContentView(for content: NotchContentProtocol) -> some View {
        Group {
            if notchViewModel.isDisplayingExpandedLiveActivity {
                content.makeExpandedView()
            } else {
                content.makeView()
            }
        }
        .id(content.id)
    }
    
    private var shouldApplyPressScale: Bool {
        let isExpandedPresentation = notchViewModel.isDisplayingExpandedLiveActivity
        let isPresentationHidden = (notchViewModel.isActivityPresentationHidden && !notchViewModel.isLocked) && notchViewModel.displayedContent == nil
        let isScreenshotContent = notchViewModel.displayedContent?.id == NotchContentRegistry.Screenshot.active.id
        return !isExpandedPresentation && !isPresentationHidden && !isScreenshotContent
    }
    
}
