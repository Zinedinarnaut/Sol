import Foundation

struct ControllerInputSnapshot: Hashable {
    var leftStickX: Float = 0
    var leftStickY: Float = 0
    var rightStickX: Float = 0
    var rightStickY: Float = 0
    var dpadX: Float = 0
    var dpadY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var leftShoulder: Bool = false
    var rightShoulder: Bool = false
    var buttonA: Bool = false
    var buttonB: Bool = false
    var buttonX: Bool = false
    var buttonY: Bool = false
    var buttonMenu: Bool = false
    var buttonOptions: Bool = false
    var buttonHome: Bool = false
    var leftThumbstickButton: Bool = false
    var rightThumbstickButton: Bool = false
    var touchpadButton: Bool = false
    var touchpadPrimaryX: Float = 0
    var touchpadPrimaryY: Float = 0
    var touchpadSecondaryX: Float = 0
    var touchpadSecondaryY: Float = 0

    func newlyPressedPhysicalButton(
        comparedTo previous: ControllerInputSnapshot
    ) -> SolEnginePhysicalButton? {
        if buttonA && !previous.buttonA { return .a }
        if buttonB && !previous.buttonB { return .b }
        if buttonX && !previous.buttonX { return .x }
        if buttonY && !previous.buttonY { return .y }
        if leftShoulder && !previous.leftShoulder { return .leftShoulder }
        if rightShoulder && !previous.rightShoulder { return .rightShoulder }
        if leftTrigger > 0.65 && previous.leftTrigger <= 0.4 { return .leftTrigger }
        if rightTrigger > 0.65 && previous.rightTrigger <= 0.4 { return .rightTrigger }
        if dpadY > 0.65 && previous.dpadY <= 0.4 { return .dpadUp }
        if dpadY < -0.65 && previous.dpadY >= -0.4 { return .dpadDown }
        if dpadX < -0.65 && previous.dpadX >= -0.4 { return .dpadLeft }
        if dpadX > 0.65 && previous.dpadX <= 0.4 { return .dpadRight }
        if buttonOptions && !previous.buttonOptions { return .minus }
        if buttonMenu && !previous.buttonMenu { return .plus }
        if buttonHome && !previous.buttonHome { return .guide }
        if leftThumbstickButton && !previous.leftThumbstickButton { return .leftStick }
        if rightThumbstickButton && !previous.rightThumbstickButton { return .rightStick }
        if touchpadButton && !previous.touchpadButton { return .touchpad }
        return nil
    }
}

enum SolEngineLogicalControl: String, CaseIterable, Identifiable, Hashable {
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case buttonL
    case buttonR
    case buttonZL
    case buttonZR
    case buttonMinus
    case buttonPlus
    case leftStick
    case rightStick
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttonA: return "A (right)"
        case .buttonB: return "B (bottom)"
        case .buttonX: return "X (top)"
        case .buttonY: return "Y (left)"
        case .buttonL: return "L"
        case .buttonR: return "R"
        case .buttonZL: return "ZL"
        case .buttonZR: return "ZR"
        case .buttonMinus: return "Minus"
        case .buttonPlus: return "Plus"
        case .leftStick: return "Left stick click"
        case .rightStick: return "Right stick click"
        case .dpadUp: return "D-Pad up"
        case .dpadDown: return "D-Pad down"
        case .dpadLeft: return "D-Pad left"
        case .dpadRight: return "D-Pad right"
        }
    }

    static let faceButtons: [Self] = [.buttonA, .buttonB, .buttonX, .buttonY]
    static let shoulderButtons: [Self] = [.buttonL, .buttonR, .buttonZL, .buttonZR]
    static let systemButtons: [Self] = [.buttonMinus, .buttonPlus, .leftStick, .rightStick]
    static let directionalButtons: [Self] = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]
}

enum SolEnginePhysicalButton: String, CaseIterable, Identifiable, Hashable {
    case unbound = "Unbound"
    case a = "A"
    case b = "B"
    case x = "X"
    case y = "Y"
    case leftStick = "LeftStick"
    case rightStick = "RightStick"
    case leftShoulder = "LeftShoulder"
    case rightShoulder = "RightShoulder"
    case leftTrigger = "LeftTrigger"
    case rightTrigger = "RightTrigger"
    case dpadUp = "DpadUp"
    case dpadDown = "DpadDown"
    case dpadLeft = "DpadLeft"
    case dpadRight = "DpadRight"
    case minus = "Minus"
    case plus = "Plus"
    case guide = "Guide"
    case misc1 = "Misc1"
    case paddle1 = "Paddle1"
    case paddle2 = "Paddle2"
    case paddle3 = "Paddle3"
    case paddle4 = "Paddle4"
    case touchpad = "Touchpad"

    var id: String { rawValue }

    static func fromEngineName(_ name: String) -> Self? {
        switch name {
        case "Back": return .minus
        case "Start": return .plus
        default: return Self(rawValue: name)
        }
    }

    func title(isDualSense: Bool) -> String {
        if isDualSense {
            switch self {
            case .a: return "Cross"
            case .b: return "Circle"
            case .x: return "Square"
            case .y: return "Triangle"
            case .leftShoulder: return "L1"
            case .rightShoulder: return "R1"
            case .leftTrigger: return "L2"
            case .rightTrigger: return "R2"
            case .leftStick: return "L3"
            case .rightStick: return "R3"
            case .minus: return "Create"
            case .plus: return "Options"
            case .guide: return "PS"
            case .touchpad: return "Touchpad"
            default: break
            }
        }

        switch self {
        case .unbound: return "Unbound"
        case .a, .b, .x, .y: return rawValue
        case .leftStick: return "Left stick click"
        case .rightStick: return "Right stick click"
        case .leftShoulder: return "Left shoulder"
        case .rightShoulder: return "Right shoulder"
        case .leftTrigger: return "Left trigger"
        case .rightTrigger: return "Right trigger"
        case .dpadUp: return "D-Pad up"
        case .dpadDown: return "D-Pad down"
        case .dpadLeft: return "D-Pad left"
        case .dpadRight: return "D-Pad right"
        case .minus: return "Back / Select"
        case .plus: return "Start / Menu"
        case .guide: return "Home / Guide"
        case .misc1: return "Extra button"
        case .paddle1: return "Paddle 1"
        case .paddle2: return "Paddle 2"
        case .paddle3: return "Paddle 3"
        case .paddle4: return "Paddle 4"
        case .touchpad: return "Touchpad"
        }
    }
}

struct SolEngineControllerMapping: Equatable {
    let inputID: String
    let inputName: String
    let player: SolEnginePlayerIndex
    var bindings: [SolEngineLogicalControl: SolEnginePhysicalButton]
    var tuning: SolEngineControllerTuning
}

struct SolEngineControllerTuning: Equatable {
    var deadzoneLeft: Double = 0.1
    var deadzoneRight: Double = 0.1
    var rangeLeft: Double = 1
    var rangeRight: Double = 1
    var triggerThreshold: Double = 0.5
    var motionEnabled = true
    var motionSensitivity = 100
    var gyroDeadzone: Double = 1
    var rumbleEnabled = false
    var strongRumble: Double = 1
    var weakRumble: Double = 1
    var hdRumble = false
    var ledEnabled = false
    var ledOff = false
    var ledRainbow = false
    var ledColor: UInt32 = 0x007AFF
}

struct ControllerInfo: Identifiable, Hashable {
    let id: UUID
    let name: String
    let vendorName: String?
    let productCategory: String
    let isAttachedToDevice: Bool
    let batteryLevel: Float?
    let batteryState: String?
    let supportsHaptics: Bool
    let supportsLight: Bool
    let supportsDualSense: Bool
    let input: ControllerInputSnapshot
}

enum DualSenseTriggerMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case feedback = "Feedback"
    case weapon = "Weapon"
    case vibration = "Vibration"
    case slopeFeedback = "Slope"

    var id: String { rawValue }
}

struct DualSenseTriggerSettings: Hashable {
    var mode: DualSenseTriggerMode = .off
    var startPosition: Float = 0.1
    var endPosition: Float = 0.8
    var strength: Float = 0.7
    var startStrength: Float = 0.2
    var endStrength: Float = 0.8
    var amplitude: Float = 0.7
    var frequency: Float = 0.5
}

enum TriggerSide {
    case left
    case right
}
