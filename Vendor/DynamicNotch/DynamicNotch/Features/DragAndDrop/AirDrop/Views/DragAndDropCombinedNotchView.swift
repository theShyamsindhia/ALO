//
//  DragAndDropCombinedNotchView.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 4/25/26.
//

import SwiftUI

struct DragAndDropCombinedNotchView: View {
    @Environment(\.isDynamicIsland) private var isDynamicIsland
    @ObservedObject var airDropViewModel: AirDropNotchViewModel

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: AirDropDropZoneMetrics.combinedSpacing) {
                ForEach(DragAndDropActivityMode.combined.targets, id: \.self) { target in
                    DragAndDropDropZoneContent(
                        target: target,
                        isTargeted: airDropViewModel.targetedDropTarget == target
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: AirDropDropZoneMetrics.height,
                        maxHeight: AirDropDropZoneMetrics.height
                    )
                }
            }
        }
        .padding(.horizontal, isDynamicIsland ? 10 : AirDropDropZoneMetrics.horizontalPadding)
        .padding(.vertical, isDynamicIsland ? 10 : AirDropDropZoneMetrics.verticalPadding)
    }
}
