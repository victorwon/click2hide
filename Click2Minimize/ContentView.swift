import SwiftUI

struct ContentView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var isClickToHideEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "ClickToHideEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "ClickToHideEnabled") // Set default value
            return true
        }
        return UserDefaults.standard.bool(forKey: "ClickToHideEnabled")
    }()
    
    var body: some View {
        VStack(spacing: 2) {
            Toggle("Enable Click2Hide", isOn: $isClickToHideEnabled)
                .padding()
                // .toggleStyle(SwitchToggleStyle(tint: .blue)) // this breaks intel mac
                .onChange(of: isClickToHideEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ClickToHideEnabled")
                    NotificationCenter.default.post(name: NSNotification.Name("ClickToHideStateChanged"), object: newValue)
                }

            Text("*If the app doesn't work as expected, please ensure that accessibility and automation permissions are enabled via app's menubar menu.")
                .font(.footnote)
                .padding(15)   
                .foregroundColor(.orange) // Optional: Change color to red for emphasis
                .multilineTextAlignment(.center) 
        }
        .frame(width: 240, height: 150)

    }
}

