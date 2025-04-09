import MCP
import Foundation
import CoreGraphics // Still needed for CGPoint, CGEventFlags
import MacosUseSDK // <-- Import the SDK

// --- Helper to serialize Swift structs to JSON String ---
func serializeToJsonString<T: Encodable>(_ value: T) -> String? {
    let encoder = JSONEncoder()
    // Use pretty printing for easier debugging of the output if needed
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let jsonData = try encoder.encode(value)
        return String(data: jsonData, encoding: .utf8)
    } catch {
        fputs("error: serializeToJsonString: failed to encode value to JSON: \(error)\n", stderr)
        return nil
    }
}

// --- Function to get arguments from MCP Value ---
// Helper to extract typed values safely
func getRequiredString(from args: [String: Value]?, key: String) throws -> String {
    guard let val = args?[key]?.stringValue else {
        throw MCPError.invalidParams("Missing or invalid required string argument: '\(key)'")
    }
    return val
}

func getRequiredDouble(from args: [String: Value]?, key: String) throws -> Double {
    guard let value = args?[key] else {
        throw MCPError.invalidParams("Missing required number argument: '\(key)'")
    }
    switch value {
    case .int(let intValue):
        fputs("log: getRequiredDouble: converting int \(intValue) to double for key '\(key)'\n", stderr)
        return Double(intValue)
    case .double(let doubleValue):
        return doubleValue
    default:
        throw MCPError.invalidParams("Invalid type for required number argument: '\(key)', expected Int or Double, got \(value)")
    }
}

func getRequiredInt(from args: [String: Value]?, key: String) throws -> Int {
    guard let value = args?[key] else {
        throw MCPError.invalidParams("Missing required integer argument: '\(key)'")
    }
    // Allow conversion from Double if it's an exact integer
    if let doubleValue = value.doubleValue {
        if let intValue = Int(exactly: doubleValue) {
             fputs("log: getRequiredInt: converting exact double \(doubleValue) to int for key '\(key)'\n", stderr)
             return intValue
        } else {
            fputs("warning: getRequiredInt: received non-exact double \(doubleValue) for key '\(key)', expecting integer.\n", stderr)
            throw MCPError.invalidParams("Invalid type for required integer argument: '\(key)', received non-exact Double \(doubleValue)")
        }
    }
    // Otherwise, require it to be an Int directly
    guard let intValue = value.intValue else {
        throw MCPError.invalidParams("Invalid type for required integer argument: '\(key)', expected Int or exact Double, got \(value)")
    }
    return intValue
}


// --- Get Optional arguments ---
// Helper for optional values
func getOptionalDouble(from args: [String: Value]?, key: String) throws -> Double? {
    guard let value = args?[key] else { return nil } // Key not present is valid for optional
    if value.isNull { return nil } // Explicit null is also valid
    switch value {
    case .int(let intValue):
        fputs("log: getOptionalDouble: converting int \(intValue) to double for key '\(key)'\n", stderr)
        return Double(intValue)
    case .double(let doubleValue):
        return doubleValue
    default:
        throw MCPError.invalidParams("Invalid type for optional number argument: '\(key)', expected Int or Double, got \(value)")
    }
}

func getOptionalInt(from args: [String: Value]?, key: String) throws -> Int? {
    guard let value = args?[key] else { return nil } // Key not present is valid for optional
    if value.isNull { return nil } // Explicit null is also valid

    if let doubleValue = value.doubleValue {
        if let intValue = Int(exactly: doubleValue) {
             fputs("log: getOptionalInt: converting exact double \(doubleValue) to int for key '\(key)'\n", stderr)
             return intValue
        } else {
            fputs("warning: getOptionalInt: received non-exact double \(doubleValue) for key '\(key)', expecting integer.\n", stderr)
            throw MCPError.invalidParams("Invalid type for optional integer argument: '\(key)', received non-exact Double \(doubleValue)")
        }
    }
    guard let intValue = value.intValue else {
        throw MCPError.invalidParams("Invalid type for optional integer argument: '\(key)', expected Int or exact Double, got \(value)")
    }
    return intValue
}

func getOptionalBool(from args: [String: Value]?, key: String) throws -> Bool? {
     guard let value = args?[key] else { return nil } // Key not present
     if value.isNull { return nil } // Explicit null
     guard let boolValue = value.boolValue else {
         throw MCPError.invalidParams("Invalid type for optional boolean argument: '\(key)', expected Bool, got \(value)")
     }
     return boolValue
}

// --- NEW Helper to parse modifier flags ---
func parseFlags(from value: Value?) throws -> CGEventFlags {
    guard let arrayValue = value?.arrayValue else {
        // No flags provided or not an array, return empty flags
        return []
    }

    var flags: CGEventFlags = []
    for flagValue in arrayValue {
        guard let flagString = flagValue.stringValue else {
            throw MCPError.invalidParams("Invalid modifierFlags array: contains non-string element \(flagValue)")
        }
        switch flagString.lowercased() {
            // Standard modifiers
            case "capslock", "caps": flags.insert(.maskAlphaShift)
            case "shift": flags.insert(.maskShift)
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "opt", "alt": flags.insert(.maskAlternate)
            case "command", "cmd": flags.insert(.maskCommand)
            // Other potentially useful flags
            case "help": flags.insert(.maskHelp)
            case "function", "fn": flags.insert(.maskSecondaryFn)
            case "numericpad", "numpad": flags.insert(.maskNumericPad)
            // Non-keyed state (less common for press simulation)
            // case "noncoalesced": flags.insert(.maskNonCoalesced)
            default:
                fputs("warning: parseFlags: unknown modifier flag string '\(flagString)', ignoring.\n", stderr)
                // Optionally throw an error:
                // throw MCPError.invalidParams("Unknown modifier flag: '\(flagString)'")
        }
    }
    return flags
}

// Async helper function to set up and start the server
func setupAndStartServer() async throws -> Server {
    fputs("log: setupAndStartServer: entering function.\n", stderr)

    // --- Define Schemas and Tools for Simplified Actions ---
    // (Schemas remain the same as they define the MCP interface)
    let openAppSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "identifier": .object(["type": .string("string"), "description": .string("REQUIRED. App name, path, or bundle ID.")])
        ]),
        "required": .array([.string("identifier")])
    ])
    let openAppTool = Tool(
        name: "macos-use_open_application_and_traverse",
        description: "Opens/activates an application and then traverses its accessibility tree.",
        inputSchema: openAppSchema
    )

    let clickSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "pid": .object(["type": .string("number"), "description": .string("REQUIRED. PID of the target application window.")]),
            "x": .object(["type": .string("number"), "description": .string("REQUIRED. X coordinate for the click.")]),
            "y": .object(["type": .string("number"), "description": .string("REQUIRED. Y coordinate for the click.")])
            // Add optional options here if needed later
        ]),
        "required": .array([.string("pid"), .string("x"), .string("y")])
    ])
    let clickTool = Tool(
        name: "macos-use_click_and_traverse",
        description: "Simulates a click at the given coordinates within the app specified by PID, then traverses its accessibility tree.",
        inputSchema: clickSchema
    )

    let typeSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "pid": .object(["type": .string("number"), "description": .string("REQUIRED. PID of the target application window.")]),
            "text": .object(["type": .string("string"), "description": .string("REQUIRED. Text to type.")])
             // Add optional options here if needed later
       ]),
        "required": .array([.string("pid"), .string("text")])
    ])
    let typeTool = Tool(
        name: "macos-use_type_and_traverse",
        description: "Simulates typing text into the app specified by PID, then traverses its accessibility tree.",
        inputSchema: typeSchema
    )

    let refreshSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "pid": .object(["type": .string("number"), "description": .string("REQUIRED. PID of the application to traverse.")])
             // Add optional options here if needed later
        ]),
        "required": .array([.string("pid")])
    ])
    let refreshTool = Tool(
        name: "macos-use_refresh_traversal",
        description: "Traverses the accessibility tree of the application specified by PID.",
        inputSchema: refreshSchema
    )

    // *** NEW: Schema and Tool for Press Key ***
    let pressKeySchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "pid": .object(["type": .string("number"), "description": .string("REQUIRED. PID of the target application window.")]),
            "keyName": .object(["type": .string("string"), "description": .string("REQUIRED. Name of the key to press (e.g., 'Return', 'Enter', 'Escape', 'Tab', 'ArrowUp', 'Delete', 'a', 'B'). Case-sensitive for letter keys if no modifiers used.")]),
            "modifierFlags": .object([ // Optional array of strings
                "type": .string("array"),
                "description": .string("OPTIONAL. Modifier keys to hold (e.g., ['Command', 'Shift']). Valid: CapsLock, Shift, Control, Option, Command, Function, NumericPad, Help."),
                "items": .object(["type": .string("string")]) // Items in the array must be strings
            ])
            // Add optional ActionOptions overrides here if needed later
        ]),
        "required": .array([.string("pid"), .string("keyName")])
    ])
    let pressKeyTool = Tool(
        name: "macos-use_press_key_and_traverse",
        description: "Simulates pressing a specific key (like Return, Enter, Escape, Tab, Arrow Keys, regular characters) with optional modifiers, then traverses the accessibility tree.",
        inputSchema: pressKeySchema
    )

    // --- Aggregate list of tools ---
    let allTools = [openAppTool, clickTool, typeTool, pressKeyTool, refreshTool]
    fputs("log: setupAndStartServer: defined \(allTools.count) tools: \(allTools.map { $0.name })\n", stderr)

    let server = Server(
        name: "SwiftMacOSServerDirect", // Renamed slightly
        version: "1.3.0", // Incremented version for major change
        capabilities: .init(
            tools: .init(listChanged: true)
        )
    )
    fputs("log: setupAndStartServer: server instance created (\(server.name)) version \(server.version).\n", stderr)

    // --- Dummy Handlers (ReadResource, ListResources, ListPrompts) ---
    // (Keep these as they are part of the MCP spec, even if unused for now)
    await server.withMethodHandler(ReadResource.self) { params in
        let uri = params.uri
        fputs("log: handler(ReadResource): received request for uri: \(uri) (dummy handler)\n", stderr)
        // In a real scenario, you might fetch resource content here
        return .init(contents: [.text("dummy content for \(uri)", uri: uri)])
    }
    fputs("log: setupAndStartServer: registered ReadResource handler (dummy).\n", stderr)

    await server.withMethodHandler(ListResources.self) { _ in
        fputs("log: handler(ListResources): received request (dummy handler).\n", stderr)
        // In a real scenario, list available resources
        return ListResources.Result(resources: [])
    }
    fputs("log: setupAndStartServer: registered ListResources handler (dummy).\n", stderr)

    await server.withMethodHandler(ListPrompts.self) { _ in
        fputs("log: handler(ListPrompts): received request (dummy handler).\n", stderr)
        // In a real scenario, list available prompts
        return ListPrompts.Result(prompts: [])
    }
    fputs("log: setupAndStartServer: registered ListPrompts handler (dummy).\n", stderr)

    // --- ListTools Handler ---
    await server.withMethodHandler(ListTools.self) { _ in
        fputs("log: handler(ListTools): received request.\n", stderr)
        let result = ListTools.Result(tools: allTools)
        fputs("log: handler(ListTools): responding with \(result.tools.count) tools: \(result.tools.map { $0.name })\n", stderr)
        return result
    }
    fputs("log: setupAndStartServer: registered ListTools handler.\n", stderr)

    // --- UPDATED CallTool Handler (Direct SDK Call) ---
    await server.withMethodHandler(CallTool.self) { params in
        fputs("log: handler(CallTool): received request for tool: \(params.name).\n", stderr)
        fputs("log: handler(CallTool): arguments received (raw MCP): \(params.arguments?.debugDescription ?? "nil")\n", stderr)

        do {
            // --- Determine Action and Options from MCP Params ---
            let primaryAction: PrimaryAction
            var options = ActionOptions() // Start with default options

            // PID is required for click, type, press, refresh
            // Optional only for open (where SDK finds it)
            let pidOptionalInt = try getOptionalInt(from: params.arguments, key: "pid")

            // Convert Int? to pid_t?
            let pidForOptions: pid_t?
            if let unwrappedPid = pidOptionalInt {
                guard let convertedPid = pid_t(exactly: unwrappedPid) else {
                    fputs("error: handler(CallTool): PID value \(unwrappedPid) is out of range for pid_t (Int32).\n", stderr)
                    throw MCPError.invalidParams("PID value \(unwrappedPid) is out of range.")
                }
                pidForOptions = convertedPid
            } else {
                pidForOptions = nil
            }
            options.pidForTraversal = pidForOptions

            // Potentially allow overriding default options from params
            options.traverseBefore = try getOptionalBool(from: params.arguments, key: "traverseBefore") ?? options.traverseBefore
            options.traverseAfter = try getOptionalBool(from: params.arguments, key: "traverseAfter") ?? options.traverseAfter
            options.showDiff = try getOptionalBool(from: params.arguments, key: "showDiff") ?? options.showDiff
            options.onlyVisibleElements = try getOptionalBool(from: params.arguments, key: "onlyVisibleElements") ?? options.onlyVisibleElements
            options.showAnimation = try getOptionalBool(from: params.arguments, key: "showAnimation") ?? options.showAnimation
            options.animationDuration = try getOptionalDouble(from: params.arguments, key: "animationDuration") ?? options.animationDuration
            options.delayAfterAction = try getOptionalDouble(from: params.arguments, key: "delayAfterAction") ?? options.delayAfterAction

             options = options.validated()
             fputs("log: handler(CallTool): constructed ActionOptions: \(options)\n", stderr)


            switch params.name {
            case openAppTool.name:
                let identifier = try getRequiredString(from: params.arguments, key: "identifier")
                primaryAction = .open(identifier: identifier)

            case clickTool.name:
                guard let reqPid = pidForOptions else { throw MCPError.invalidParams("Missing required 'pid' for click tool") }
                let x = try getRequiredDouble(from: params.arguments, key: "x")
                let y = try getRequiredDouble(from: params.arguments, key: "y")
                primaryAction = .input(action: .click(point: CGPoint(x: x, y: y)))
                options.pidForTraversal = reqPid // Re-affirm

            case typeTool.name:
                guard let reqPid = pidForOptions else { throw MCPError.invalidParams("Missing required 'pid' for type tool") }
                let text = try getRequiredString(from: params.arguments, key: "text")
                primaryAction = .input(action: .type(text: text))
                options.pidForTraversal = reqPid // Re-affirm

            // *** NEW CASE for Press Key ***
            case pressKeyTool.name:
                guard let reqPid = pidForOptions else { throw MCPError.invalidParams("Missing required 'pid' for press key tool") }
                let keyName = try getRequiredString(from: params.arguments, key: "keyName")
                // Parse optional flags using the new helper
                let flags = try parseFlags(from: params.arguments?["modifierFlags"])
                fputs("log: handler(CallTool): parsed modifierFlags: \(flags)\n", stderr)
                primaryAction = .input(action: .press(keyName: keyName, flags: flags))
                options.pidForTraversal = reqPid // Re-affirm

            case refreshTool.name:
                guard let reqPid = pidForOptions else { throw MCPError.invalidParams("Missing required 'pid' for refresh tool") }
                primaryAction = .traverseOnly
                options.pidForTraversal = reqPid // Re-affirm

            default:
                fputs("error: handler(CallTool): received request for unknown or unsupported tool: \(params.name)\n", stderr)
                throw MCPError.methodNotFound(params.name)
            }

            fputs("log: handler(CallTool): constructed PrimaryAction: \(primaryAction)\n", stderr)

            // --- Execute the Action using MacosUseSDK ---
            let actionResult: ActionResult = await Task { @MainActor in
                fputs("log: handler(CallTool): executing performAction on MainActor via Task...\n", stderr)
                return await performAction(action: primaryAction, optionsInput: options)
            }.value
            fputs("log: handler(CallTool): performAction task completed.\n", stderr)

            // --- Serialize the ActionResult to JSON ---
            guard let resultJsonString = serializeToJsonString(actionResult) else {
                fputs("error: handler(CallTool): failed to serialize ActionResult to JSON for tool \(params.name).\n", stderr)
                throw MCPError.internalError("failed to serialize ActionResult to JSON")
            }
            fputs("log: handler(CallTool): successfully serialized ActionResult to JSON string:\n\(resultJsonString)\n", stderr)

            // --- Determine if it was an error overall ---
            let isError = actionResult.primaryActionError != nil ||
                          (options.traverseBefore && actionResult.traversalBeforeError != nil) ||
                          (options.traverseAfter && actionResult.traversalAfterError != nil)

            if isError {
                 fputs("warning: handler(CallTool): Action resulted in an error state (primary: \(actionResult.primaryActionError ?? "nil"), before: \(actionResult.traversalBeforeError ?? "nil"), after: \(actionResult.traversalAfterError ?? "nil")).\n", stderr)
            }

            // --- Return the JSON result ---
            let content: [Tool.Content] = [.text(resultJsonString)]
            return .init(content: content, isError: isError)

        } catch let error as MCPError {
             fputs("error: handler(CallTool): MCPError occurred processing MCP params for tool '\(params.name)': \(error)\n", stderr)
             return .init(content: [.text("Error processing parameters for tool '\(params.name)': \(error.localizedDescription)")], isError: true)
        } catch {
             fputs("error: handler(CallTool): Unexpected error occurred setting up call for tool '\(params.name)': \(error)\n", stderr)
             return .init(content: [.text("Unexpected setup error executing tool '\(params.name)': \(error.localizedDescription)")], isError: true)
        }
    }
    fputs("log: setupAndStartServer: registered CallTool handler.\n", stderr)


    // --- Transport and Start ---
    let transport = StdioTransport()
    fputs("log: setupAndStartServer: created StdioTransport.\n", stderr)

    fputs("log: setupAndStartServer: calling server.start()...\n", stderr)
    try await server.start(transport: transport)
    fputs("log: setupAndStartServer: server.start() completed (background task launched).\n", stderr)

    fputs("log: setupAndStartServer: returning server instance.\n", stderr)
    return server
}

// --- @main Entry Point ---
@main
struct MCPServer {
    // Main entry point - Async
    static func main() async {
        fputs("log: main: starting server (async).\n", stderr)

        // Configure logging if needed (optional)
        // LoggingSystem.bootstrap { label in MultiplexLogHandler([...]) }

        let server: Server
        do {
            fputs("log: main: calling setupAndStartServer()...\n", stderr)
            server = try await setupAndStartServer()
            fputs("log: main: setupAndStartServer() successful, server instance obtained.\n", stderr)

            fputs("log: main: server started, calling server.waitUntilCompleted()...\n", stderr)
            await server.waitUntilCompleted() // Waits until the server loop finishes/errors
            fputs("log: main: server.waitUntilCompleted() returned. Server has stopped.\n", stderr)

        } catch {
            fputs("error: main: server setup or run failed: \(error)\n", stderr)
            if let mcpError = error as? MCPError {
                 fputs("error: main: MCPError details: \(mcpError.localizedDescription)\n", stderr)
             }
            // Consider more specific exit codes if useful
            exit(1) // Exit with error code
        }

        fputs("log: main: Server processing finished gracefully. Exiting.\n", stderr)
        exit(0) // Exit cleanly
    }
}
