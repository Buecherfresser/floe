import CoreGraphics

enum SplitAxis: Sendable {
    case vertical
    case horizontal

    var toggled: SplitAxis {
        switch self {
        case .vertical: return .horizontal
        case .horizontal: return .vertical
        }
    }
}

indirect enum BSPNode: Sendable {
    case leaf(CGWindowID)
    case split(axis: SplitAxis, ratio: Double, first: BSPNode, second: BSPNode)
}

enum BSPTree {
    /// Builds a balanced BSP tree from an ordered list of window IDs.
    /// The first window occupies the "main" side of each split.
    /// Axes alternate at each depth level (vertical first, then horizontal, etc.).
    static func build(windowIDs: [CGWindowID], axis: SplitAxis = .vertical, ratio: Double = 0.5) -> BSPNode? {
        guard !windowIDs.isEmpty else { return nil }
        if windowIDs.count == 1 {
            return .leaf(windowIDs[0])
        }

        let firstSlice = Array(windowIDs.prefix(1))
        let secondSlice = Array(windowIDs.dropFirst())

        guard let first = build(windowIDs: firstSlice, axis: axis.toggled, ratio: ratio),
              let second = build(windowIDs: secondSlice, axis: axis.toggled, ratio: ratio) else {
            return nil
        }

        return .split(axis: axis, ratio: ratio, first: first, second: second)
    }

    /// Builds a fully balanced tree where windows are distributed evenly across both subtrees.
    static func buildBalanced(windowIDs: [CGWindowID], axis: SplitAxis = .vertical) -> BSPNode? {
        guard !windowIDs.isEmpty else { return nil }
        if windowIDs.count == 1 {
            return .leaf(windowIDs[0])
        }

        let mid = windowIDs.count / 2
        let leftSlice = Array(windowIDs.prefix(mid))
        let rightSlice = Array(windowIDs.suffix(from: mid))

        guard let left = buildBalanced(windowIDs: leftSlice, axis: axis.toggled),
              let right = buildBalanced(windowIDs: rightSlice, axis: axis.toggled) else {
            return nil
        }

        return .split(axis: axis, ratio: 0.5, first: left, second: right)
    }
}

extension BSPNode {
    /// Recursively calculates the frame for each leaf window within the given rect.
    /// `outerGap` is applied only at the top level; `innerGap` is applied between splits.
    func calculateFrames(
        in rect: CGRect,
        innerGap: CGFloat,
        outerGap: CGFloat,
        isRoot: Bool = true
    ) -> [(CGWindowID, CGRect)] {
        let workArea: CGRect
        if isRoot {
            workArea = rect.insetBy(dx: outerGap, dy: outerGap)
        } else {
            workArea = rect
        }

        switch self {
        case .leaf(let windowID):
            return [(windowID, workArea)]

        case .split(let axis, let ratio, let first, let second):
            let halfGap = innerGap / 2.0

            let firstRect: CGRect
            let secondRect: CGRect

            switch axis {
            case .vertical:
                let splitX = workArea.origin.x + workArea.width * ratio
                firstRect = CGRect(
                    x: workArea.origin.x,
                    y: workArea.origin.y,
                    width: splitX - workArea.origin.x - halfGap,
                    height: workArea.height
                )
                secondRect = CGRect(
                    x: splitX + halfGap,
                    y: workArea.origin.y,
                    width: workArea.maxX - splitX - halfGap,
                    height: workArea.height
                )

            case .horizontal:
                let splitY = workArea.origin.y + workArea.height * ratio
                firstRect = CGRect(
                    x: workArea.origin.x,
                    y: workArea.origin.y,
                    width: workArea.width,
                    height: splitY - workArea.origin.y - halfGap
                )
                secondRect = CGRect(
                    x: workArea.origin.x,
                    y: splitY + halfGap,
                    width: workArea.width,
                    height: workArea.maxY - splitY - halfGap
                )
            }

            let firstFrames = first.calculateFrames(in: firstRect, innerGap: innerGap, outerGap: outerGap, isRoot: false)
            let secondFrames = second.calculateFrames(in: secondRect, innerGap: innerGap, outerGap: outerGap, isRoot: false)
            return firstFrames + secondFrames
        }
    }
}
