import Foundation

public enum FileSizeFormatter {
    public static func openFinderString(fromByteCount bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let units: [(name: String, factor: Double)] = [
            ("KB", 1_000),
            ("MB", 1_000_000),
            ("GB", 1_000_000_000),
            ("TB", 1_000_000_000_000)
        ]
        let value: Double
        let unit: String
        if bytes < 1_000_000 {
            value = max(1, ceil(Double(bytes) / 1_000))
            unit = "KB"
        } else if bytes < 1_000_000_000 {
            value = Double(bytes) / 1_000_000
            unit = "MB"
        } else if bytes < 1_000_000_000_000 {
            value = Double(bytes) / 1_000_000_000
            unit = "GB"
        } else {
            value = Double(bytes) / units.last!.factor
            unit = units.last!.name
        }
        return "\(formatted(value)) \(unit)"
    }

    private static func formatted(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        var displayValue = (value * 10).rounded() / 10
        if displayValue >= 1_000, value < 1_000 {
            displayValue = floor(value * 10) / 10
        }
        if displayValue.rounded() == displayValue {
            return String(Int(displayValue))
        }
        return String(format: "%.1f", displayValue)
    }
}
