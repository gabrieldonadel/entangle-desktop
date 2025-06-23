import SwiftUI
import Network
import CoreGraphics

// MARK: - Data Structure for Trackpad Events
/// Defines the data structure for trackpad events sent from the iOS device.
/// This struct must be identical in both the iOS client and macOS server applications.
struct TrackpadEvent: Codable {
    enum EventType: String, Codable {
        case move
        case singleClick
        case scroll
    }

    let type: EventType
    // For .move events: contains the new normalized position (x, y between 0.0 and 1.0)
    // For .scroll events: contains the scroll deltas (dx, dy)
    let point: CGPoint
}

// MARK: - Input Event Manager
/// Handles the creation and posting of system-level input events (CGEvents).
class InputEventManager {

    /// Checks if the application has Accessibility permissions.
    /// These permissions are required to programmatically control the mouse and keyboard.
    static func checkAccessibilityPermissions() -> Bool {
        // An old API is used for checking permissions, by creating a dummy event.
        // If this returns true, it's a good indicator, but not foolproof.
        // The most reliable check is to try posting an event and see if it works.
        let checkOptionPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [checkOptionPrompt: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return accessEnabled
    }

    /// Opens the Accessibility section in System Settings for the user.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Processes a received TrackpadEvent and converts it into a native CGEvent.
    /// - Parameter event: The decoded event from the iOS device.
    func handle(event: TrackpadEvent) {
        guard let mainScreen = NSScreen.main else {
            print("Error: Could not find main screen.")
            return
        }
        let screenFrame = mainScreen.frame

        switch event.type {
        case .move:
            // Convert normalized coordinates (0.0-1.0) to screen coordinates.
            let targetX = screenFrame.origin.x + (event.point.x * screenFrame.width)
            let targetY = screenFrame.origin.y + (event.point.y * screenFrame.height)
            let targetPoint = CGPoint(x: targetX, y: targetY)
            postMoveEvent(to: targetPoint)

        case .singleClick:
            // A click happens at the current cursor position.
            guard let currentLocation = CGEvent(source: nil)?.location else { return }
            postClickEvents(at: currentLocation)

        case .scroll:
            // The point contains scroll deltas directly.
            let deltaX = Int32(event.point.x)
            let deltaY = Int32(event.point.y)
            postScrollEvent(deltaX: deltaX, deltaY: deltaY)
        }
    }

    private func postMoveEvent(to position: CGPoint) {
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
    }

    private func postClickEvents(at position: CGPoint) {
        let mouseDownEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left)
        let mouseUpEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left)

        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    /// Posts a scroll wheel event using pixel units for a smooth, trackpad-like feel.
    private func postScrollEvent(deltaX: Int32, deltaY: Int32) {
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                        units: .pixel, // Use .pixel for smooth scrolling
                                        wheelCount: 2,
                                        wheel1: deltaY, // Vertical scroll
                                        wheel2: deltaX, // Horizontal scroll
                                        wheel3: 0)
        else {
            print("Failed to create scroll event")
            return
        }
        scrollEvent.post(tap: .cghidEventTap)
    }
}


// MARK: - Network Server
/// Listens for incoming UDP connections from the iOS device over peer-to-peer Wi-Fi.
@MainActor
class TrackpadServer: ObservableObject {
    @Published var serverStatus: String = "Idle"
    @Published var lastReceivedMessage: String = "None"
    @Published var hasAccessibilityPermissions: Bool = false

    public var listener: NWListener?
    private var connection: NWConnection?
    private let inputManager = InputEventManager()

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        self.hasAccessibilityPermissions = InputEventManager.checkAccessibilityPermissions()
    }

    func startServer() {
        // Use a custom Bonjour service name. This must match the client app.
        let service = NWListener.Service(name: "MyMac-Trackpad", type: "_mytrackpad._tcp")

        // Configure parameters for UDP and enable peer-to-peer networking.
        let params = NWParameters.udp
        params.includePeerToPeer = true

        do {
          if #available(macOS 13.0, *) {
            listener = try NWListener(service: service, using: params)
          }
        } catch {
            serverStatus = "Failed to create listener: \(error.localizedDescription)"
            return
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                switch newState {
                case .ready:
                    self?.serverStatus = "Listening on port \(self?.listener?.port?.debugDescription ?? "N/A")"
                case .failed(let error):
                    self?.serverStatus = "Listener failed: \(error.localizedDescription)"
                    self?.stopServer()
                case .cancelled:
                     self?.serverStatus = "Cancelled"
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] newConnection in
            DispatchQueue.main.async {
                if let existingConnection = self?.connection {
                    existingConnection.cancel()
                }
                self?.connection = newConnection
                self?.handleConnection(newConnection)
                self?.serverStatus = "Connected to \(newConnection.endpoint.debugDescription)"
            }
        }

        listener?.start(queue: .main)
    }

    func stopServer() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        serverStatus = "Idle"
        lastReceivedMessage = "None"
    }

    private func handleConnection(_ connection: NWConnection) {
      connection.stateUpdateHandler = { [weak self] state in
        // Explicitly dispatch to the main queue to satisfy MainActor isolation.
        DispatchQueue.main.async {
          guard let self = self else { return }

          switch state {
          case .ready:
            print("Connection ready")
            self.receive()
          case .failed(let error):
            print("Connection failed: \(error.localizedDescription)")
            self.serverStatus = "Connection failed"
          case .cancelled:
            print("Connection cancelled")
            self.serverStatus = "Connection cancelled by peer"
          default:
            break
          }
        }
      }
      connection.start(queue: .main)
    }

    private func receive() {
        connection?.receiveMessage { [weak self] (content, context, isComplete, error) in
          if #available(macOS 12.0, *) {
            if let data = content, !data.isEmpty {
              self?.processReceivedData(data)
              self?.lastReceivedMessage = "Received \(data.count) bytes at \(Date().formatted(date: .omitted, time: .standard))"
            }
          }
            if error == nil {
                // If the connection is still open, schedule the next receive.
                self?.receive()
            }
        }
    }

    private func processReceivedData(_ data: Data) {
        let decoder = JSONDecoder()
        do {
            let trackpadEvent = try decoder.decode(TrackpadEvent.self, from: data)
            if hasAccessibilityPermissions {
                inputManager.handle(event: trackpadEvent)
            } else {
                 DispatchQueue.main.async {
                    self.lastReceivedMessage = "Received event, but no Accessibility permissions."
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.lastReceivedMessage = "Error decoding message: \(error.localizedDescription)"
            }
        }
    }
}


// MARK: - SwiftUI View
struct ContentView: View {
    @StateObject private var server = TrackpadServer()

    var body: some View {
        VStack(spacing: 15) {
            Text("Wireless Trackpad Server")
                .font(.largeTitle)
                .fontWeight(.bold)

            Divider()

            // --- Status Section ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Status").font(.headline)
                HStack {
                    Circle()
                        .fill(server.serverStatus.contains("Listening") || server.serverStatus.contains("Connected") ? .green : .red)
                        .frame(width: 12, height: 12)
                    Text(server.serverStatus)
                        .font(.body)
                }
                HStack {
                    Image(systemName: "arrow.down.circle.dotted")
                    Text(server.lastReceivedMessage)
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)

            // --- Accessibility Permissions ---
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Permissions").font(.headline)
                    Spacer()
                    Button {
                        server.checkPermissions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .buttonStyle(.plain) // Use plain style for a less prominent button
                    .foregroundColor(.accentColor)
                }

                HStack {
                    Image(systemName: server.hasAccessibilityPermissions ? "lock.open.fill" : "lock.fill")
                        .foregroundColor(server.hasAccessibilityPermissions ? .green : .red)
                    Text("Accessibility Access:")
                    Text(server.hasAccessibilityPermissions ? "Granted" : "Denied")
                        .fontWeight(.bold)
                        .foregroundColor(server.hasAccessibilityPermissions ? .green : .red)
                }

                if !server.hasAccessibilityPermissions {
                    Text("This app needs permission to control the cursor. Please grant access in System Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Open Privacy & Security Settings") {
                        InputEventManager.openAccessibilitySettings()
                    }

                    Text("Tip: If you've already granted permission, try removing the app from the list in System Settings, adding it back, and then clicking the 'Refresh' button above.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 5)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)


            Spacer()

            // --- Control Buttons ---
            HStack(spacing: 20) {
                Button(action: {
                    server.startServer()
                }) {
                    Label("Start Listening", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .disabled(server.listener != nil)

                Button(action: {
                    server.stopServer()
                }) {
                    Label("Stop", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(server.listener == nil)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 400)
        .onAppear {
            // Re-check permissions when the view appears or app becomes active
             NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                server.checkPermissions()
            }
        }
    }
}

// MARK: - App Entry Point
@main
struct TrackpadServerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
