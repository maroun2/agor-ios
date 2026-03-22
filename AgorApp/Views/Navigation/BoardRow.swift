import SwiftUI

struct BoardRow: View {
    let board: Board
    var attentionCount: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(board.displayIcon)
                .font(.title3)

            Text(board.name)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
            }
        }
    }
}
