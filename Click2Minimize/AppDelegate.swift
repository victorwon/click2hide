import Cocoa
import CoreGraphics
import SwiftUI
import ApplicationServices
import Combine // Add Combine framework
import ServiceManagement
import Foundation

@main // This indicates that this is the entry point of the application
struct Click2MinimizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Click2Hide", image: "MenuBarIcon") {
            Button(action: appDelegate.openPopupWindow, label: { Text("Settings") })
            Divider()
            
            // New button to open System Preferences for Accessibility
            Button(action: appDelegate.openAccessibilityPreferences, label: { Text("Accessibility Preferences") })

            // New button to open System Preferences for Automation
            Button(action: appDelegate.openAutomationPreferences, label: { Text("Automation Preferences") })
            Divider()

            Button(action: appDelegate.quitApp, label: { Text("Quit") })
        }
    }

    init() {
        // Retrieve the current version and build number from Info.plist
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            appDelegate.currentVersion = "\(version).\(build)" // Combine version and build number
        }
        appDelegate.checkForUpdates()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var eventTap: CFMachPort?
    var mainWindow: NSWindow?
    var cancellables = Set<AnyCancellable>()
    var dockItems: [DockItem] = [] // Global variable to hold dock item rectangles
    private var isClickToHideEnabled: Bool = { // Set isClickToHideEnabled to true if not found
        if UserDefaults.standard.object(forKey: "ClickToHideEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "ClickToHideEnabled") // Set default value
            return true
        }
        return UserDefaults.standard.bool(forKey: "ClickToHideEnabled")
    }() 
    var appDict: [String: String] = [:]
    var currentVersion: String = "" // Add this line to define currentVersion
    private var debounceTimer: Timer?
     
    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }
    
    func openSettingsWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            let contentView = ContentView()
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Version \(currentVersion)"
            window.styleMask = [.titled, .closable]
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.mainWindow = window
        }
    }
    
    @objc func openPopupWindow() {
        openSettingsWindow()
        if let w = self.mainWindow {
            w.level = .floating // make it stay on top of others
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Check for accessibility permissions
        if !isAccessibilityEnabled() {
            promptForAccessibilityPermission()
        }

        // Set the application to be an accessory application
        NSApplication.shared.setActivationPolicy(.accessory)

        // Register for ClickToHideStateChanged notifications
        NotificationCenter.default.addObserver(self, selector: #selector(updateClickToHideState(_:)), name: NSNotification.Name("ClickToHideStateChanged"), object: nil)

        // Start observing Dock changes.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        registerLoginItem() // Register the helper application as a login item
        setupAppDict()
        setupEventTap()
        
        print("Application did finish launching")
        
        // Initial load of dock items
        updateDockItems()
    }

    @objc func dockChanged(notification: Notification) {
        // Update dock items whenever a relevant event occurs
        updateDockItems()
    }

    @objc func updateDockItems() {
        // Check if the debounce timer is already running
        if debounceTimer == nil {
            // Create a new timer that will reset the debounce period
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.debounceTimer = nil // Reset the timer
            }
            
            // Perform the update immediately
            performDockUpdate()
        }
    }

    private func performDockUpdate() {
        // Call getDockRects() to update the global dockItems variable
        getDockRects().sink { dockItems in
            self.dockItems = dockItems ?? []
        }.store(in: &cancellables)
        print("-- performDockUpdate --")
    }

    func setupAppDict() {
        appDict["Visual Studio Code"] = "Code"
        appDict["Rosetta Stone Learn Languages"] = "Rosetta Stone"
    }
    
    func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) // Capture only left mouse clicks
        
        // Create the event tap
        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                // Retrieve the AppDelegate from refcon
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                return AppDelegate.eventTapCallback(proxy: proxy, type: type, event: event, appDelegate: appDelegate)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque() // Pass the AppDelegate as userInfo
        ) else {
            print("Failed to create event tap")
            return
        }

        // Create the run loop source with the event tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Store the event tap reference
        self.eventTap = eventTap
        print("Event tap created successfully")
    }

    static func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent?, appDelegate: AppDelegate) -> Unmanaged<CGEvent>? {
        guard let event = event else { return nil }
        
        // Skip if not enabled, during change, or if the active application is in fullscreen
        if !appDelegate.isClickToHideEnabled || appDelegate.isActiveAppFullscreen() {
            return Unmanaged.passUnretained(event) // Allow the event to pass through
        }
        
        let mouseLocation = event.location
        var shouldSuppressEvent = false // Track if the event should be suppressed

        // Check if the mouse is over any dock item using the global dockItems variable
        for dockItem in appDelegate.dockItems {
            if dockItem.rect.contains(mouseLocation) {
                // Log the mouse location and app name
                print("Mouse Location: \(mouseLocation), App Name: \(dockItem.appID)")
                if "Launchpad||Trash||Downloads".contains(dockItem.appID) {
                    // these are not working for sure
                    return Unmanaged.passUnretained(event)
                }
                // Find the running application by name using NSWorkspace
                let runningApps = NSWorkspace.shared.runningApplications
                if let app = runningApps.first(where: { $0.localizedName == dockItem.appID
                    || $0.localizedName == appDelegate.appDict[dockItem.appID] }) {
                    print("App isHidden: \(app.isHidden), isActive: \(app.isActive)")
                    // when app is just minimized without switching focus, it's hidden but still active
                    // there is no simple way to differentiate but good news is next click will work
                    if !app.isActive || app.isHidden {
                        // Use launch as app.activate() is not reliable and can't unminimize
                        NSWorkspace.shared.launchApplication(dockItem.appID)
                        // must be set after launchApp() to get most consistent results
                        app.unhide()
                        app.activate()
                    } else {
                        let success = app.hide() // Minimize the app
                        print("App minimized \(success): \(app.localizedName ?? "Unknown")")
                    }
                    shouldSuppressEvent = true
                } else {
                    // Print all running applications' localized names
                    let runningAppNames = runningApps.map { $0.localizedName ?? "Unknown" }
                    print("No running application found with name: \(dockItem.appID).\nRunning apps: \(runningAppNames.joined(separator: " | "))")
                
                }
            }
        }
        
        return shouldSuppressEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func isActiveAppFullscreen() -> Bool {
        // Get the list of windows for the active application
        let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.isKeyWindow }
        
        // Check if any window is in fullscreen mode
        for window in windows {
            if window.styleMask.contains(.fullSizeContentView) {
                return true
            }
        }
        
        return false
    }

    // Define a struct to hold the dock item information
    struct DockItem {
        let rect: NSRect
        let appID: String
    }

    func getDockRects() -> Future<[DockItem]?, Never> {
        return Future { promise in
            DispatchQueue.global(qos: .userInitiated).async {
                var dockItems: [DockItem] = []
                
                let script = """
                tell application "System Events"
                    set dockItemList to {}
                    tell process "Dock"
                        set dockItems to every UI element of list 1
                        repeat with dockItem in dockItems
                            set dockPosition to position of dockItem
                            set dockSize to size of dockItem
                            set appID to name of dockItem -- Get the application name
                            set end of dockItemList to {dockPosition, dockSize, appID}
                        end repeat
                        return dockItemList
                    end tell
                end tell
                """
                
                var error: NSDictionary?
                if let appleScript = NSAppleScript(source: script) {
                    let result = appleScript.executeAndReturnError(&error)
                    if error != nil {
                        print("Error executing AppleScript: \(String(describing: error))")
                        promise(.success(nil))
                        return
                    }
                    
                    if result.descriptorType == typeAEList {
                        for index in 1...result.numberOfItems {
                            if let item = result.atIndex(index) {
                                // Each item is an array containing position, size, and app ID
                                if let positionDescriptor = item.atIndex(1),
                                   let sizeDescriptor = item.atIndex(2),
                                   let appIDDescriptor = item.atIndex(3) {
                                    
                                    // Extract position values
                                    let positionX = positionDescriptor.atIndex(1)?.doubleValue ?? 0
                                    let positionY = positionDescriptor.atIndex(2)?.doubleValue ?? 0
                                    
                                    // Extract size values
                                    let sizeWidth = sizeDescriptor.atIndex(1)?.doubleValue ?? 0
                                    let sizeHeight = sizeDescriptor.atIndex(2)?.doubleValue ?? 0
                                    
                                    // Extract app ID (name)
                                    let appID = appIDDescriptor.stringValue ?? "Unknown"
                                    
                                    let rect = NSRect(x: positionX, y: positionY, width: sizeWidth, height: sizeHeight)
                                    let dockItem = DockItem(rect: rect, appID: appID)
                                    dockItems.append(dockItem)
                                }
                            }
                        }
                    }
                }
                
                promise(.success(dockItems))
            }
        }
    }

    func registerLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            try SMAppService.mainApp.register()
        } catch {
            print("Error setting login item: \(error.localizedDescription)")
        }
    }

    @objc func updateClickToHideState(_ notification: Notification) {
        if let enabled = notification.object as? Bool {
            isClickToHideEnabled = enabled
            // Save the new state to UserDefaults
            UserDefaults.standard.set(enabled, forKey: "ClickToHideEnabled")
        }
    }

    func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }

    func promptForAccessibilityPermission() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = 
        """
        To allow Click2Hide to control the system dock, please enable accessibility permissions for it in System Preferences.
        
        Please relaunch app after permission granted.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Preferences")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilityPreferences()
            // Quit the application as it won't work without permission
            // Delay termination by 1 second
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func openAccessibilityPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openAutomationPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    func checkForUpdates() {
        let url = URL(string: "https://api.github.com/repos/victorwon/click2hide/releases/latest")!
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("Error fetching updates: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            if let releaseInfo = try? JSONDecoder().decode(Release.self, from: data) {
                // Compare with current version and prompt user if an update is available
                if self.isNewerVersion(releaseInfo.tag_name, currentVersion: self.currentVersion) {
                    DispatchQueue.main.async {
                        self.promptUserToUpdate(releaseInfo)
                    }
                }
            }
        }
        task.resume()
    }

    private func isNewerVersion(_ newVersion: String, currentVersion: String) -> Bool {
        let newVersionComponents = newVersion.split(separator: ".").map { Int($0) ?? 0 }
        let currentVersionComponents = currentVersion.split(separator: ".").map { Int($0) ?? 0 }

        for (new, current) in zip(newVersionComponents, currentVersionComponents) {
            if new > current {
                return true
            } else if new < current {
                return false
            }
        }
        return newVersionComponents.count > currentVersionComponents.count
    }

    private func promptUserToUpdate(_ releaseInfo: Release) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "A new version \(releaseInfo.tag_name) is available. Would you like to update?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Fetch the latest DMG URL from the release info
            fetchLatestDMG(releaseInfo: releaseInfo)
        }
    }

    private func fetchLatestDMG(releaseInfo: Release) {
        let url = URL(string: "https://api.github.com/repos/victorwon/click2hide/releases/latest")!
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("Error fetching release info: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let downloadURL = asset["browser_download_url"] as? String,
                       let name = asset["name"] as? String,
                       name.hasSuffix(".dmg") {
                        self.downloadDMG(from: downloadURL)
                        break
                    }
                }
            }
        }
        task.resume()
    }

    private func downloadDMG(from urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            guard let localURL = localURL, error == nil else {
                print("Error downloading DMG: \(error?.localizedDescription ?? "Unknown error")")
                // Open the browser link for manual upgrade
                self.openBrowserForManualUpgrade()
                return
            }
            
            // Mount the DMG
            let mountTask = Process()
            mountTask.launchPath = "/usr/bin/hdiutil"
            mountTask.arguments = ["attach", localURL.path]

            mountTask.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    // Get the mounted volume path
                    let mountedVolumePath = "/Volumes/Click2Hide" // Adjust this if the volume name is different
                    let appDestinationURL = URL(fileURLWithPath: "/Applications/Click2Hide.app") // Change to /Applications

                    do {
                        // Copy the app to the /Applications folder
                        let appSourceURL = URL(fileURLWithPath: "\(mountedVolumePath)/Click2Hide.app") // Adjust if necessary
                        if FileManager.default.fileExists(atPath: appDestinationURL.path) {
                            try FileManager.default.removeItem(at: appDestinationURL) // Remove old version if it exists
                        }
                        try FileManager.default.copyItem(at: appSourceURL, to: appDestinationURL)
                        print("Successfully installed Click2Hide to /Applications.")
                        
                        // Prompt the user to relaunch the app
                        DispatchQueue.main.async {
                            self.promptUserToRelaunch()
                        }
                        
                    } catch {
                        print("Error copying app to /Applications: \(error.localizedDescription)")
                        // Open the browser link for manual upgrade
                        self.openBrowserForManualUpgrade()
                    }

                    // Unmount the DMG
                    let unmountTask = Process()
                    unmountTask.launchPath = "/usr/bin/hdiutil"
                    unmountTask.arguments = ["detach", mountedVolumePath]
                    unmountTask.launch()
                    unmountTask.waitUntilExit()
                } else {
                    print("Failed to mount DMG.")
                    // Open the browser link for manual upgrade
                    self.openBrowserForManualUpgrade()
                }
            }
            
            mountTask.launch()
        }
        task.resume()
    }

    private func openBrowserForManualUpgrade() {
        if let url = URL(string: "https://github.com/victorwon/click2hide/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    private func promptUserToRelaunch() {
        let alert = NSAlert()
        alert.messageText = "Update Successful"
        alert.informativeText = "The application has been successfully updated."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Relaunch")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Relaunch the app
            NSWorkspace.shared.launchApplication("/Applications/Click2Hide.app")
        }
        
        // Delay termination by 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApplication.shared.terminate(nil)
        }
    }

    struct Release: Codable {
        let tag_name: String
    }
}
