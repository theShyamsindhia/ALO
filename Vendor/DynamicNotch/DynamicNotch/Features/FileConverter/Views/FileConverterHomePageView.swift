//
//  FileConverterHomePageView.swift
//  DynamicNotch
//
//  Created by Евгений Петрукович on 7/22/26.
//

import SwiftUI

struct FileConverterHomePageView: View {
    var onRequestCollapse: (@MainActor () -> Void)? = nil
    
    @ObservedObject var fileConverterViewModel: FileConverterViewModel
    @Environment(\.isDynamicIsland) private var isDynamicIsland
    
    var body: some View {
        VStack {
            Spacer()
            emptyStateDropRow
        }
        .padding(.horizontal, 1)
        .padding(.bottom, 1)
    }
    
    private var emptyStateDropRow: some View {
        Button(action: {
            onRequestCollapse?()
            DispatchQueue.main.async {
                fileConverterViewModel.chooseFileFromFinder()
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: isDynamicIsland ? 24 : 34)
                    .fill(.gray.opacity(0.12))
                    .stroke(.gray.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [10, 10]))
                    .frame(height: 110)

                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(verbatim: "Click to select file")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(fileConverterViewModel.isConverting)
        .buttonStyle(.plain)
    }
}
