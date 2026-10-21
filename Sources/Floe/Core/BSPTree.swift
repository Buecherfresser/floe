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

// MARK: - User-Adjusted Ratios
//
// Split ratios the user changed by resizing a window are stored per split,
// keyed by the split's path from the root ("" = root, "0" = first child,
// "01" = first child's second child, …). The tree shape is deterministic for
// a given window list, so the paths stay valid until windows are added or
// removed.

extension BSPNode {
    /// The same tree with ratios replaced where `ratios` has an entry.
    func applying(ratios: [String: Double], path: String = "") -> BSPNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis,
                ratio: ratios[path] ?? ratio,
                first: first.applying(ratios: ratios, path: path + "0"),
                second: second.applying(ratios: ratios, path: path + "1")
            )
        }
    }

    private func contains(_ windowID: CGWindowID) -> Bool {
        switch self {
        case .leaf(let id): return id == windowID
        case .split(_, _, let first, let second): return first.contains(windowID) || second.contains(windowID)
        }
    }

    /// Ratio changes that move the window's tile edges to `target`.
    ///
    /// Each edge of a tile is set by exactly one split: the right edge by the
    /// nearest vertical split the window sits in the first half of, the left
    /// edge by the nearest one it sits in the second half of (same for
    /// horizontal splits and bottom/top). Edges that didn't move are ignored.
    func ratios(
        fitting windowID: CGWindowID,
        to target: CGRect,
        in rect: CGRect,
        innerGap: CGFloat,
        outerGap: CGFloat
    ) -> [String: Double] {
        var ancestors: [(path: String, axis: SplitAxis, area: CGRect, inFirst: Bool)] = []
        var tile: CGRect?
        collectAncestors(of: windowID, in: rect.insetBy(dx: outerGap, dy: outerGap), innerGap: innerGap,
                         path: "", into: &ancestors, tile: &tile)
        guard let tile else { return [:] }

        let halfGap = innerGap / 2
        let threshold: CGFloat = 1
        var result: [String: Double] = [:]

        // Nearest ancestor first.
        func nearest(_ axis: SplitAxis, inFirst: Bool) -> (path: String, area: CGRect)? {
            ancestors.last { $0.axis == axis && $0.inFirst == inFirst }.map { ($0.path, $0.area) }
        }
        func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0.1), 0.9)) }

        if abs(target.maxX - tile.maxX) > threshold, let split = nearest(.vertical, inFirst: true) {
            result[split.path] = clamp((target.maxX + halfGap - split.area.minX) / split.area.width)
        }
        if abs(target.minX - tile.minX) > threshold, let split = nearest(.vertical, inFirst: false) {
            result[split.path] = clamp((target.minX - halfGap - split.area.minX) / split.area.width)
        }
        if abs(target.maxY - tile.maxY) > threshold, let split = nearest(.horizontal, inFirst: true) {
            result[split.path] = clamp((target.maxY + halfGap - split.area.minY) / split.area.height)
        }
        if abs(target.minY - tile.minY) > threshold, let split = nearest(.horizontal, inFirst: false) {
            result[split.path] = clamp((target.minY - halfGap - split.area.minY) / split.area.height)
        }
        return result
    }

    private func collectAncestors(
        of windowID: CGWindowID,
        in area: CGRect,
        innerGap: CGFloat,
        path: String,
        into ancestors: inout [(path: String, axis: SplitAxis, area: CGRect, inFirst: Bool)],
        tile: inout CGRect?
    ) {
        switch self {
        case .leaf(let id):
            if id == windowID { tile = area }
        case .split(let axis, let ratio, let first, let second):
            let halfGap = innerGap / 2
            let (firstRect, secondRect): (CGRect, CGRect)
            switch axis {
            case .vertical:
                let splitX = area.minX + area.width * ratio
                firstRect = CGRect(x: area.minX, y: area.minY, width: splitX - area.minX - halfGap, height: area.height)
                secondRect = CGRect(x: splitX + halfGap, y: area.minY, width: area.maxX - splitX - halfGap, height: area.height)
            case .horizontal:
                let splitY = area.minY + area.height * ratio
                firstRect = CGRect(x: area.minX, y: area.minY, width: area.width, height: splitY - area.minY - halfGap)
                secondRect = CGRect(x: area.minX, y: splitY + halfGap, width: area.width, height: area.maxY - splitY - halfGap)
            }
            if first.contains(windowID) {
                ancestors.append((path, axis, area, true))
                first.collectAncestors(of: windowID, in: firstRect, innerGap: innerGap, path: path + "0", into: &ancestors, tile: &tile)
            } else if second.contains(windowID) {
                ancestors.append((path, axis, area, false))
                second.collectAncestors(of: windowID, in: secondRect, innerGap: innerGap, path: path + "1", into: &ancestors, tile: &tile)
            }
        }
    }
}

extension BSPNode {
    /// Which edges of the window's tile border a split (and can be resized).
    /// Edges on the screen boundary can't move.
    func movableEdges(of windowID: CGWindowID) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        var edges = (left: false, right: false, top: false, bottom: false)
        var node = self
        while case .split(let axis, _, let first, let second) = node {
            let inFirst = first.containsLeaf(windowID)
            guard inFirst || second.containsLeaf(windowID) else { break }
            switch (axis, inFirst) {
            case (.vertical, true): edges.right = true
            case (.vertical, false): edges.left = true
            case (.horizontal, true): edges.bottom = true
            case (.horizontal, false): edges.top = true
            }
            node = inFirst ? first : second
        }
        return edges
    }

    fileprivate func containsLeaf(_ windowID: CGWindowID) -> Bool {
        switch self {
        case .leaf(let id): return id == windowID
        case .split(_, _, let first, let second): return first.containsLeaf(windowID) || second.containsLeaf(windowID)
        }
    }
}
