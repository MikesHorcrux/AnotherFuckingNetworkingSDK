/// An amortized constant-time FIFO queue for deterministic test doubles.
struct FIFOQueue<Element: Sendable>: Sendable {
    private var storage: [Element]
    private var headIndex = 0

    init(_ elements: [Element] = []) {
        storage = elements
    }

    var isEmpty: Bool {
        headIndex == storage.endIndex
    }

    var count: Int {
        storage.count - headIndex
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard headIndex < storage.endIndex else { return nil }
        let element = storage[headIndex]
        headIndex += 1

        if headIndex >= 64, headIndex >= storage.count / 2 {
            storage.removeFirst(headIndex)
            headIndex = 0
        }
        return element
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        headIndex = 0
    }
}
