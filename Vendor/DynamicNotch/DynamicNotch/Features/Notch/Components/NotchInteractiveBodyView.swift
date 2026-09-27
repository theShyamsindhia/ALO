import SwiftUI

struct NotchInteractiveBodyView: View {
    @ObservedObject var notchViewModel: NotchViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    
    var body: some View {
        NotchSurfaceContainerView(
            notchViewModel: notchViewModel
        )
        .shadow(
            color: (notchViewModel.presentedNotchSize.height >= notchViewModel.notchModel.baseHeight + 30)
            ? .black.opacity(0.4) : .clear, radius: 20
        )
        .frame(
            width: notchViewModel.presentedNotchSize.width,
            height: notchViewModel.presentedNotchSize.height,
            alignment: .top
        )
        .customNotchPressable(
            notchViewModel: notchViewModel,
            isPressed: $notchViewModel.isPressed,
            baseSize: notchViewModel.presentedNotchSize
        )
        .offset(y: notchViewModel.isDynamicIsland ? 3 : 0)
        .customNotchMouseSwipeable(
            notchViewModel: notchViewModel,
            isEnabled: shouldEnableNotchSwipeGestures
        )
        .customNotchSwipeDismissable(
            notchViewModel: notchViewModel,
            isEnabled: shouldEnableNotchSwipeGestures
        )
        .contextMenu {
            NotchContextMenu(settingsViewModel: settingsViewModel)
        }
        .environment(\.colorScheme, .dark)
        .animation(notchViewModel.animations.notchVisibility, value: notchViewModel.showNotch)
    }
    
    private var shouldEnableNotchSwipeGestures: Bool {
        guard (!notchViewModel.isActivityPresentationHidden || notchViewModel.isLocked) || notchViewModel.notchModel.temporaryNotificationContent != nil else { return false }
        
        return !(
            notchViewModel.isDisplayingExpandedLiveActivity &&
            (notchViewModel.displayedContent?.id == RoomInteractionContent.activityID ||
             notchViewModel.displayedContent?.id == NotchContentRegistry.DragAndDrop.trayActive.id ||
             (notchViewModel.displayedContent?.id == NotchContentRegistry.HomePage.active.id && settingsViewModel.homePage.homePageScrollAxis == .vertical))
        )
    }
}
