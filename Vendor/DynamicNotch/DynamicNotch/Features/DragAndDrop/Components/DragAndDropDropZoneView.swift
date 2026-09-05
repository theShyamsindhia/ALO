//
//  DragAndDropDropZoneView.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 4/25/26.
//

import SwiftUI

enum AirDropDropZoneMetrics {
    static let cornerRadius: CGFloat = 18
    static let width: CGFloat = .infinity
    static let height: CGFloat = 90
    static let horizontalPadding: CGFloat = 36
    static let verticalPadding: CGFloat = 12
    static let combinedSpacing: CGFloat = 12
}

struct DragAndDropDropZoneView: View {
    let target: DragAndDropTarget
    let isTargeted: Bool
    
    var body: some View {
        VStack {
            Spacer()
            
            DragAndDropDropZoneContent(
                target: target,
                isTargeted: isTargeted
            )
            .frame(maxWidth: .infinity, maxHeight: AirDropDropZoneMetrics.height)
        }
        .padding(.horizontal, AirDropDropZoneMetrics.horizontalPadding)
        .padding(.vertical, AirDropDropZoneMetrics.verticalPadding)
    }
}

struct DragAndDropDropZoneContent: View {
    let target: DragAndDropTarget
    let isTargeted: Bool

    var body: some View {
        switch target {
        case .airDrop:
            AirDropDropZoneContent(isTargeted: isTargeted)
        case .tray:
            TrayDropZoneContent(isTargeted: isTargeted)
        }
    }
}
