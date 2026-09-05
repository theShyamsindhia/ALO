//
//  FileConverterHomePageNotchContent.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 7/22/26.
//

import SwiftUI

struct FileConverterHomePageNotchContent: NotchContentProtocol, DynamicIslandCustomizable {
    let id = NotchContentRegistry.HomePage.active.id
    let fileConverterViewModel: FileConverterViewModel
    let onRequestCollapse: (@MainActor () -> Void)?

    init(
        fileConverterViewModel: FileConverterViewModel,
        onRequestCollapse: (@MainActor () -> Void)? = nil
    ) {
        self.fileConverterViewModel = fileConverterViewModel
        self.onRequestCollapse = onRequestCollapse
    }

    var priority: Int { NotchContentRegistry.HomePage.active.priority }
    var isExpandable: Bool { true }

    func size(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        .init(width: baseWidth, height: baseHeight)
    }

    func expandedCornerRadius(baseRadius: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        (top: 24, bottom: 48)
    }

    func expandedSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        .init(width: baseWidth + 65, height: baseHeight + 125)
    }

    func expandedDynamicIslandSize(baseWidth: CGFloat, baseHeight: CGFloat) -> CGSize {
        .init(width: baseWidth + 95, height: baseHeight + 125)
    }

    func expandedDynamicIslandCornerRadius(baseHeight: CGFloat) -> CGFloat {
        baseHeight * 0.2
    }

    @MainActor
    func makeView() -> AnyView {
        AnyView(EmptyView())
    }

    @MainActor
    func makeExpandedView() -> AnyView {
        AnyView(
            FileConverterHomePageView(
                onRequestCollapse: onRequestCollapse,
                fileConverterViewModel: fileConverterViewModel
            )
        )
    }
}
