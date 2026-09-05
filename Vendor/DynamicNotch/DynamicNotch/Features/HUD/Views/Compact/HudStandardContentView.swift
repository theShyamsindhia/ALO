import SwiftUI

struct HudStandardContentView: View {
    @Environment(\.notchScale) private var scale
    @Environment(\.isDynamicIsland) private var isDynamicIsland
    
    let kind: HudPresentationKind
    let level: Int
    let indicatorStyle: HudIndicatorStyle
    let indicatorTintStyle: HudIndicatorTintStyle
    let showsIndicatorGlow: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: kind.title)
                .font(.system(size: 14))
                .foregroundColor(.white)
            
            Spacer()
            
            indicatorView
        }
        .padding(.vertical, 10)
        .padding(.leading, leadingPadding.scaled(by: scale))
        .padding(.trailing, trailingPadding.scaled(by: scale))
    }
    
    private var indicatorView: some View {
        HudLevelIndicatorView(
            level: clampedLevel,
            indicatorStyle: indicatorStyle,
            tintStyle: indicatorTintStyle,
            showsGlow: showsIndicatorGlow,
            barWidth: barIndicatorWidth,
            barHeight: barIndicatorHeight,
            circleSize: circleIndicatorSize,
            circleLineWidth: circleIndicatorLineWidth
        )
    }
    
    private var trailingPadding: CGFloat {
        let basePadding = indicatorStyle == .circle
            ? (isDynamicIsland ? 4 : 16)
            : (isDynamicIsland ? 8 : 16)
        return CGFloat(basePadding)
    }
    
    private var leadingPadding: CGFloat {
        let basePadding = indicatorStyle == .circle
            ? (isDynamicIsland ? 8 : 16)
            : (isDynamicIsland ? 8 : 16)
        return CGFloat(basePadding)
    }
    
    private var barIndicatorWidth: CGFloat {
        50
    }
    
    private var barIndicatorHeight: CGFloat {
        6
    }
    
    private var circleIndicatorSize: CGFloat {
        isDynamicIsland ? 16 : 19
    }
    
    private var circleIndicatorLineWidth: CGFloat {
        3
    }
    
    private var clampedLevel: Int {
        max(0, min(100, level))
    }
}
