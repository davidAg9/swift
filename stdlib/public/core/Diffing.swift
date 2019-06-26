//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2015 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// MARK: Diff application to RangeReplaceableCollection

@available(macOS 9999, iOS 9999, tvOS 9999, watchOS 9999, *) // FIXME(availability-5.1)
extension CollectionDifference {
  fileprivate func _fastEnumeratedApply(
    _ consume: (Change) -> Void
  ) {
    let totalRemoves = removals.count
    let totalInserts = insertions.count
    var enumeratedRemoves = 0
    var enumeratedInserts = 0

    while enumeratedRemoves < totalRemoves || enumeratedInserts < totalInserts {
      let change: Change
      if enumeratedRemoves < removals.count && enumeratedInserts < insertions.count {
        let removeOffset = removals[enumeratedRemoves]._offset
        let insertOffset = insertions[enumeratedInserts]._offset
        if removeOffset - enumeratedRemoves <= insertOffset - enumeratedInserts {
          change = removals[enumeratedRemoves]
        } else {
          change = insertions[enumeratedInserts]
        }
      } else if enumeratedRemoves < totalRemoves {
        change = removals[enumeratedRemoves]
      } else if enumeratedInserts < totalInserts {
        change = insertions[enumeratedInserts]
      } else {
        // Not reached, loop should have exited.
        preconditionFailure()
      }

      consume(change)

      switch change {
      case .remove(_, _, _):
        enumeratedRemoves += 1
      case .insert(_, _, _):
        enumeratedInserts += 1
      }
    }
  }
}

extension RangeReplaceableCollection {
  /// Applies the given difference to this collection.
  ///
  /// - Parameter difference: The difference to be applied.
  ///
  /// - Returns: An instance representing the state of the receiver with the
  ///   difference applied, or `nil` if the difference is incompatible with
  ///   the receiver's state.
  ///
  /// - Complexity: O(*n* + *c*), where *n* is `self.count` and *c* is the
  ///   number of changes contained by the parameter.
  @available(macOS 9999, iOS 9999, tvOS 9999, watchOS 9999, *) // FIXME(availability-5.1)
  public func applying(_ difference: CollectionDifference<Element>) -> Self? {
    var result = Self()
    var enumeratedRemoves = 0
    var enumeratedInserts = 0
    var enumeratedOriginals = 0
    var currentIndex = self.startIndex

    func append(
      into target: inout Self,
      contentsOf source: Self,
      from index: inout Self.Index, count: Int
    ) {
      let start = index
      source.formIndex(&index, offsetBy: count)
      target.append(contentsOf: source[start..<index])
    }

    difference._fastEnumeratedApply { change in
      switch change {
      case .remove(offset: let offset, element: _, associatedWith: _):
        let origCount = offset - enumeratedOriginals
        append(into: &result, contentsOf: self, from: &currentIndex, count: origCount)
        enumeratedOriginals += origCount + 1 // Removal consumes an original element
        currentIndex = self.index(after: currentIndex)
        enumeratedRemoves += 1
      case .insert(offset: let offset, element: let element, associatedWith: _):
        let origCount = (offset + enumeratedRemoves - enumeratedInserts) - enumeratedOriginals
        append(into: &result, contentsOf: self, from: &currentIndex, count: origCount)
        result.append(element)
        enumeratedOriginals += origCount
        enumeratedInserts += 1
      }
      _internalInvariant(enumeratedOriginals <= self.count)
    }
    let origCount = self.count - enumeratedOriginals
    append(into: &result, contentsOf: self, from: &currentIndex, count: origCount)

    _internalInvariant(currentIndex == self.endIndex)
    _internalInvariant(enumeratedOriginals + origCount == self.count)
    _internalInvariant(result.count == self.count + enumeratedInserts - enumeratedRemoves)
    return result
  }
}

// MARK: Definition of API

extension BidirectionalCollection {
  /// Returns the difference needed to produce this collection's ordered 
  /// elements from the given collection, using the given predicate as an 
  /// equivalence test.
  ///
  /// This function does not infer element moves. If you need to infer moves,
  /// call the `inferringMoves()` method on the resulting difference.
  ///
  /// - Parameters:
  ///   - other: The base state.
  ///   - areEquivalent: A closure that returns a Boolean value indicating 
  ///     whether two elements are equivalent.
  ///
  /// - Returns: The difference needed to produce the reciever's state from
  ///   the parameter's state.
  ///
  /// - Complexity: Worst case performance is O(*n* * *m*), where *n* is the 
  ///   count of this collection and *m* is `other.count`. You can expect 
  ///   faster execution when the collections share many common elements.
  @available(macOS 9999, iOS 9999, tvOS 9999, watchOS 9999, *) // FIXME(availability-5.1)
  public func difference<C: BidirectionalCollection>(
    from other: C,
    by areEquivalent: (C.Element, Element) -> Bool
  ) -> CollectionDifference<Element>
  where C.Element == Self.Element {
    return myers(from: other, to: self, using: areEquivalent)
  }
}

extension BidirectionalCollection where Element : Equatable {
  /// Returns the difference needed to produce this collection's ordered 
  /// elements from the given collection.
  ///
  /// This function does not infer element moves. If you need to infer moves,
  /// call the `inferringMoves()` method on the resulting difference.
  ///
  /// - Parameters:
  ///   - other: The base state.
  ///
  /// - Returns: The difference needed to produce this collection's ordered 
  ///   elements from the given collection.
  ///
  /// - Complexity: Worst case performance is O(*n* * *m*), where *n* is the 
  ///   count of this collection and *m* is `other.count`. You can expect 
  ///   faster execution when the collections share many common elements, or 
  ///   if `Element` conforms to `Hashable`.
  @available(macOS 9999, iOS 9999, tvOS 9999, watchOS 9999, *) // FIXME(availability-5.1)
  public func difference<C: BidirectionalCollection>(
    from other: C
  ) -> CollectionDifference<Element> where C.Element == Self.Element {
    return difference(from: other, by: ==)
  }
}

// MARK: Internal implementation

// V is a rudimentary type made to represent the rows of the triangular matrix type used by the Myer's algorithm
//
// This type is basically an array that only supports indexes in the set `stride(from: -d, through: d, by: 2)` where `d` is the depth of this row in the matrix
// `d` is always known at allocation-time, and is used to preallocate the structure.
fileprivate struct V {

  private var a: [Int]
#if DEBUG
  private let isOdd: Bool
#endif

  // The way negative indexes are implemented is by interleaving them in the empty slots between the valid positive indexes
  @inline(__always) private static func transform(_ index: Int) -> Int {
    // -3, -1, 1, 3 -> 3, 1, 0, 2 -> 0...3
    // -2, 0, 2 -> 2, 0, 1 -> 0...2
    return (index <= 0 ? -index : index &- 1)
  }

  init(maxIndex largest: Int) {
#if DEBUG
    assert(largest >= 0)
    isOdd = largest % 2 == 1
#endif
    a = [Int](repeating: 0, count: largest + 1)
  }

  subscript(index: Int) -> Int {
    get {
#if DEBUG
      assert(isOdd == (index % 2 != 0))
#endif
      return a[V.transform(index)]
    }
    set(newValue) {
#if DEBUG
      assert(isOdd == (index % 2 != 0))
#endif
      a[V.transform(index)] = newValue
    }
  }
}

@available(macOS 9999, iOS 9999, tvOS 9999, watchOS 9999, *) // FIXME(availability-5.1)
fileprivate func myers<C,D>(
  from old: C, to new: D,
  using cmp: (C.Element, D.Element) -> Bool
) -> CollectionDifference<C.Element>
  where
    C : BidirectionalCollection,
    D : BidirectionalCollection,
    C.Element == D.Element
{

  // Core implementation of the algorithm described at http://www.xmailserver.org/diff2.pdf
  // Variable names match those used in the paper as closely as possible
  func descent(from a: [C.Element], to b: [C.Element]) -> [V] {
    let n = a.count
    let m = b.count
    let max = n + m

    var result = [V]()
    var v = V(maxIndex: 1)
    v[1] = 0

    var x = 0
    var y = 0
    iterator: for d in 0...max {
      let prev_v = v
      result.append(v)
      v = V(maxIndex: d)

      // The code in this loop is _very_ hot—the loop bounds increases in terms
      // of the iterator of the outer loop!
      for k in stride(from: -d, through: d, by: 2) {
        if k == -d {
          x = prev_v[k &+ 1]
        } else {
          let km = prev_v[k &- 1]

          if k != d {
            let kp = prev_v[k &+ 1]
            if km < kp {
              x = kp
            } else {
              x = km &+ 1
            }
          } else {
            x = km &+ 1
          }
        }
        y = x &- k

        while x < n && y < m {
          if !cmp(a[x], b[y]) {
            break;
          }
          x &+= 1
          y &+= 1
        }

        v[k] = x

        if x >= n && y >= m {
          break iterator
        }
      }
      if x >= n && y >= m {
        break
      }
    }

    assert(x >= n && y >= m)

    return result
  }

  /* Splatting the collections into arrays here has two advantages:
   *
   *   1) Subscript access becomes inlined
   *   2) Subscript index becomes Int, matching the iterator types in the algorithm
   *
   * Combined, these effects dramatically improves performance when
   * collections differ significantly, without unduly degrading runtime when
   * the parameters are very similar.
   *
   * In terms of memory use, the linear cost is significantly less than the
   * worst-case n² memory use of the descent algorithm.
   */
  let a = Array(old)
  let b = Array(new)

  let trace = descent(from: a, to: b)

  var changes = [CollectionDifference<C.Element>.Change]()

  var x = a.count
  var y = b.count
  for d in stride(from: trace.count &- 1, to: 0, by: -1) {
    let v = trace[d]
    let k = x &- y
    let prev_k = (k == -d || (k != d && v[k &- 1] < v[k &+ 1])) ? k &+ 1 : k &- 1
    let prev_x = v[prev_k]
    let prev_y = prev_x &- prev_k

    while x > prev_x && y > prev_y {
      // No change at this position.
      x &-= 1
      y &-= 1
    }

    assert((x == prev_x && y > prev_y) || (y == prev_y && x > prev_x))
    if y != prev_y {
      changes.append(.insert(offset: prev_y, element: b[prev_y], associatedWith: nil))
    } else {
      changes.append(.remove(offset: prev_x, element: a[prev_x], associatedWith: nil))
    }

    x = prev_x
    y = prev_y
  }

  return CollectionDifference(changes)!
}
