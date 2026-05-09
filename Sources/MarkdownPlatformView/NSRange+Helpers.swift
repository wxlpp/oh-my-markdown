import Foundation

extension NSRange {
    /// Returns a copy of the range clipped so neither endpoint exists outside `[0, upperBound]`.
    func clamped(to upperBound: Int) -> NSRange {
        let location = min(max(0, self.location), upperBound)
        let end = min(max(location, self.location + max(0, self.length)), upperBound)
        return NSRange(location: location, length: end - location)
    }
}
