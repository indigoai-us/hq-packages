import FoundationModels

enum LocalAIAvailability {
    static var message: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Apple’s on-device model is ready. Draft generation is being built."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings to prepare local drafts."
        case .unavailable(.modelNotReady):
            return "Apple’s on-device model is preparing. Recording and editing will remain available."
        case .unavailable(.deviceNotEligible):
            return "Local drafts require an Apple Intelligence-compatible Mac."
        case .unavailable:
            return "Local AI is unavailable. Recording and editing will remain available."
        }
    }
}
