import SwiftUI

struct ProgressBarView: View {
    var progress: Double   // 0.0 – 1.0
    var color: Color = .blue

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemFill))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                    .animation(.linear(duration: 0.1), value: progress)
            }
        }
        .frame(height: 8)
    }
}
