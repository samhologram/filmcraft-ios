import Foundation
@preconcurrency import FilmCraftKit

/// The full human-readable text of an error, including the engine's message from `BridgeError.Failed`.
func errorText(_ error: Error) -> String {
    if let bridge = error as? BridgeError {
        switch bridge {
        case .Failed(let message): return message
        }
    }
    let described = (error as NSError).localizedDescription
    return described.isEmpty ? String(describing: error) : described
}
