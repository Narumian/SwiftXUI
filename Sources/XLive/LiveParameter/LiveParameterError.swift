import Foundation

public enum LiveParameterError: Error, Equatable, Sendable {
    case invalidRange, invalidValue, invalidPeriod, invalidReturnDuration, invalidAddress
}
