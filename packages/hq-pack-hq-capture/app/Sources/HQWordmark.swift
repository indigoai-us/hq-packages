// The HQ wordmark, drawn from the path data of the official 280x161 SVG so it needs no image
// loading and stays sharp at any size.

import SwiftUI

struct HQWordmark: Shape {
    /// The SVG's viewBox.
    static let artboard = CGSize(width: 280, height: 161)

    static let letterH = "M85.7251 3.66162H118.034V154.434H85.7251V89.8176H32.3085V154.434H0V3.66162H32.3085V57.5091H85.7251V3.66162Z"
    static let letterQ = "M257.169 160.035L241.014 144.096C235.343 147.973 229.096 150.988 222.276 153.142C215.527 155.296 208.419 156.373 200.952 156.373C190.757 156.373 181.172 154.363 172.197 150.342C163.223 146.25 155.325 140.65 148.505 133.542C141.684 126.362 136.335 118.07 132.458 108.664C128.581 99.187 126.642 89.0278 126.642 78.1865C126.642 67.417 128.581 57.3296 132.458 47.9242C136.335 38.4471 141.684 30.1187 148.505 22.939C155.325 15.7593 163.223 10.1592 172.197 6.1386C181.172 2.0462 190.757 0 200.952 0C211.219 0 220.84 2.0462 229.814 6.1386C238.789 10.1592 246.686 15.7593 253.507 22.939C260.328 30.1187 265.641 38.4471 269.446 47.9242C273.323 57.3296 275.261 67.417 275.261 78.1865C275.261 86.0123 274.184 93.5151 272.031 100.695C269.948 107.803 267.077 114.444 263.415 120.618L280 137.203L257.169 160.035ZM200.952 124.065C203.896 124.065 206.732 123.741 209.46 123.095C212.26 122.449 214.952 121.552 217.537 120.403L208.491 111.357L231.322 88.5252L239.291 96.4946C240.512 93.6946 241.409 90.7509 241.984 87.6637C242.63 84.5764 242.953 81.4173 242.953 78.1865C242.953 71.8684 241.84 65.9452 239.614 60.4168C237.461 54.8885 234.445 50.0422 230.568 45.878C226.691 41.642 222.204 38.3394 217.106 35.9701C212.08 33.529 206.696 32.3085 200.952 32.3085C195.208 32.3085 189.788 33.529 184.69 35.9701C179.664 38.3394 175.213 41.642 171.336 45.878C167.459 50.0422 164.407 54.8885 162.182 60.4168C160.028 65.9452 158.951 71.8684 158.951 78.1865C158.951 84.5046 160.028 90.4637 162.182 96.0639C164.407 101.592 167.459 106.474 171.336 110.71C175.213 114.875 179.664 118.141 184.69 120.511C189.788 122.88 195.208 124.065 200.952 124.065Z"

    /// Both letters in SVG coordinates (y grows downward, like SwiftUI).
    static let artwork: Path = {
        var path = Path()
        for data in [letterH, letterQ] { SVGPathData.append(data, to: &path) }
        return path
    }()

    /// Width for a given height, keeping the artboard's proportions.
    static func width(forHeight height: CGFloat) -> CGFloat {
        height * artboard.width / artboard.height
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.artboard.width, rect.height / Self.artboard.height)
        return Self.artwork.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}

/// Reads the absolute SVG path commands the wordmark uses: M, L, H, V, C and Z.
enum SVGPathData {
    static func append(_ data: String, to path: inout Path) {
        var scanner = Tokens(data)
        var current = CGPoint.zero
        var command: Character = "M"
        while !scanner.atEnd {
            if let letter = scanner.command() { command = letter }
            switch command {
            case "M":
                guard let point = scanner.point() else { return }
                path.move(to: point)
                current = point
                command = "L"
            case "L":
                guard let point = scanner.point() else { return }
                path.addLine(to: point)
                current = point
            case "H":
                guard let x = scanner.number() else { return }
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = scanner.number() else { return }
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)
            case "C":
                guard let c1 = scanner.point(), let c2 = scanner.point(), let end = scanner.point() else { return }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
            case "Z":
                path.closeSubpath()
                command = "M"
            default:
                return
            }
        }
    }

    private struct Tokens {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) { characters = Array(text) }

        var atEnd: Bool {
            mutating get { skipSeparators(); return index >= characters.count }
        }

        mutating func command() -> Character? {
            skipSeparators()
            guard index < characters.count, characters[index].isLetter else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
            var seenDot = false
            while index < characters.count {
                let c = characters[index]
                if c.isNumber { index += 1 } else if c == ".", !seenDot { seenDot = true; index += 1 } else { break }
            }
            guard index > start, let value = Double(String(characters[start..<index])) else { return nil }
            return CGFloat(value)
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        private mutating func skipSeparators() {
            while index < characters.count, characters[index] == " " || characters[index] == "," { index += 1 }
        }
    }
}
