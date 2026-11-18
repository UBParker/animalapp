import SwiftUI

/// Shown above the tabs while the app is running on the temporary store it opened after the real
/// store failed to open.
struct RecoveredStoreBanner: View {
    var body: some View {
        Text("The data store could not be opened. Running with a temporary store; export your data if this persists.")
            .font(.footnote)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.yellow)
    }
}
