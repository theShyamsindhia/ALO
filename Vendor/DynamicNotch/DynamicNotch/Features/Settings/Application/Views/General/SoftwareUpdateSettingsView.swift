import SwiftUI

struct SoftwareUpdateSettingsView: View {
    var body: some View {
        SettingsPageScrollView {
            SettingsCard {
                Text("Notch features update with ALO.")
                Text("Use ALO → Check for Updates to update the application.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
