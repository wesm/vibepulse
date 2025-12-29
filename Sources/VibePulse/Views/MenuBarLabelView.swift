import SwiftUI

struct MenuBarLabelView: View {
    let totalText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .symbolRenderingMode(.hierarchical)
            Text(totalText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
