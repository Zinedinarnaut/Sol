enum SolEngineVSyncMode: Int, CaseIterable, Identifiable {
    case standardTiming = 0
    case unbounded = 1
    case custom = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .standardTiming: return "Standard"
        case .unbounded: return "Unbounded"
        case .custom: return "Custom"
        }
    }
}

enum SolEngineAspectRatio: String, CaseIterable, Identifiable {
    case fixed4x3 = "Fixed4x3"
    case fixed16x9 = "Fixed16x9"
    case fixed16x10 = "Fixed16x10"
    case fixed21x9 = "Fixed21x9"
    case fixed32x9 = "Fixed32x9"
    case stretched = "Stretched"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed4x3: return "4:3"
        case .fixed16x9: return "16:9"
        case .fixed16x10: return "16:10"
        case .fixed21x9: return "21:9"
        case .fixed32x9: return "32:9"
        case .stretched: return "Stretched"
        }
    }
}

enum SolEngineAntiAliasing: String, CaseIterable, Identifiable {
    case none = "None"
    case fxaa = "Fxaa"
    case smaaLow = "SmaaLow"
    case smaaMedium = "SmaaMedium"
    case smaaHigh = "SmaaHigh"
    case smaaUltra = "SmaaUltra"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fxaa: return "FXAA"
        case .smaaLow: return "SMAA Low"
        case .smaaMedium: return "SMAA Medium"
        case .smaaHigh: return "SMAA High"
        case .smaaUltra: return "SMAA Ultra"
        }
    }
}

enum SolEngineScalingFilter: String, CaseIterable, Identifiable {
    case bilinear = "Bilinear"
    case nearest = "Nearest"
    case fsr = "Fsr"
    case area = "Area"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bilinear: return "Bilinear"
        case .nearest: return "Nearest"
        case .fsr: return "AMD FSR"
        case .area: return "Area"
        }
    }
}

enum SolEngineAudioBackend: String, CaseIterable, Identifiable {
    case audioToolbox = "AudioToolbox"
    case sdl3 = "SDL3"
    case sdl2 = "SDL2"
    case openAL = "OpenAl"
    case soundIO = "SoundIo"
    case dummy = "Dummy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audioToolbox: return "AudioToolbox"
        case .sdl3: return "SDL 3"
        case .sdl2: return "SDL 2"
        case .openAL: return "OpenAL"
        case .soundIO: return "SoundIO"
        case .dummy: return "Disabled"
        }
    }
}

enum SolEngineSystemLanguage: String, CaseIterable, Identifiable {
    case japanese = "Japanese"
    case americanEnglish = "AmericanEnglish"
    case french = "French"
    case german = "German"
    case italian = "Italian"
    case spanish = "Spanish"
    case chinese = "Chinese"
    case korean = "Korean"
    case dutch = "Dutch"
    case portuguese = "Portuguese"
    case russian = "Russian"
    case taiwanese = "Taiwanese"
    case britishEnglish = "BritishEnglish"
    case canadianFrench = "CanadianFrench"
    case latinAmericanSpanish = "LatinAmericanSpanish"
    case simplifiedChinese = "SimplifiedChinese"
    case traditionalChinese = "TraditionalChinese"
    case brazilianPortuguese = "BrazilianPortuguese"
    case polish = "Polish"
    case thai = "Thai"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .japanese: return "Japanese"
        case .americanEnglish: return "English (US)"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .spanish: return "Spanish"
        case .chinese: return "Chinese"
        case .korean: return "Korean"
        case .dutch: return "Dutch"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .taiwanese: return "Taiwanese"
        case .britishEnglish: return "English (UK)"
        case .canadianFrench: return "French (Canada)"
        case .latinAmericanSpanish: return "Spanish (Latin America)"
        case .simplifiedChinese: return "Chinese (Simplified)"
        case .traditionalChinese: return "Chinese (Traditional)"
        case .brazilianPortuguese: return "Portuguese (Brazil)"
        case .polish: return "Polish"
        case .thai: return "Thai"
        }
    }
}

enum SolEngineSystemRegion: String, CaseIterable, Identifiable {
    case japan = "Japan"
    case usa = "USA"
    case europe = "Europe"
    case australia = "Australia"
    case china = "China"
    case korea = "Korea"
    case taiwan = "Taiwan"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .japan: return "Japan"
        case .usa: return "United States"
        case .europe: return "Europe"
        case .australia: return "Australia"
        case .china: return "China"
        case .korea: return "Korea"
        case .taiwan: return "Taiwan"
        }
    }
}

enum SolEngineBackendThreading: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case off = "Off"
    case on = "On"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .off: return "Off"
        case .on: return "On"
        }
    }
}

enum SolEngineHideCursorMode: Int, CaseIterable, Identifiable {
    case never = 0
    case onIdle = 1
    case always = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .onIdle: return "When Idle"
        case .always: return "Always"
        }
    }
}

enum SolEngineMultiplayerMode: Int, CaseIterable, Identifiable {
    case disabled = 0
    case onlineRooms = 1
    case localWireless = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .onlineRooms:
            return "Online Rooms"
        case .localWireless:
            return "Local Wireless"
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            return "Run games without local-wireless multiplayer emulation."
        case .onlineRooms:
            return "Find compatible players through the configured LDN room server."
        case .localWireless:
            return "Expose local-wireless play to devices on the selected Mac network interface."
        }
    }
}

enum SolEngineMemoryConfiguration: Int, CaseIterable, Identifiable {
    case fourGiB = 0
    case sixGiB = 1
    case eightGiB = 2
    case twelveGiB = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fourGiB: return "4 GB (Console Default)"
        case .sixGiB: return "6 GB"
        case .eightGiB: return "8 GB"
        case .twelveGiB: return "12 GB"
        }
    }
}

enum SolEngineMemoryManagerMode: String, CaseIterable, Identifiable {
    case softwarePageTable = "SoftwarePageTable"
    case hostMapped = "HostMapped"
    case hostMappedUnsafe = "HostMappedUnsafe"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .softwarePageTable: return "Software Page Table"
        case .hostMapped: return "Host Mapped"
        case .hostMappedUnsafe: return "Host Mapped (Unsafe)"
        }
    }
}
