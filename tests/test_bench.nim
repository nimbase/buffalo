import unittest
import std/[monotimes, times]

import buffalo

proc checksum(o: openArray[byte]): int =
  for b in o:
    result += b.int

suite "bench: reuse vs alloc":
  test "steady-state borrows allocate nothing":
    var pool = initPool(byte, 64)
    GC_fullCollect()
    let before = getOccupiedMem()
    var total = 0
    for _ in 0 ..< 20_000:
      withBorrow(pool, buf):
        for j in 0 ..< 64:
          buf.add(byte(j))
        total += checksum(buf.toOpenArray())
    GC_fullCollect()
    let after = getOccupiedMem()
    echo "occupied before=", before, " B after=", after, " B"
    check total == 20_000 * (63 * 64 div 2)
    check pool.cap == 64 # no growth in steady state
    check after <= before + 4096 # GC bookkeeping only, no per-iter growth

  test "timing table (informational, not asserted)":
    const Iters = 2_000
    const Size = 4096
    var pattern = newSeq[byte](Size)
    for i in 0 ..< Size:
      pattern[i] = byte((i * 31) and 0xFF)

    let t0 = getMonoTime()
    var s1 = 0
    for _ in 0 ..< Iters:
      var s = newSeq[byte](Size)
      copyMem(addr s[0], unsafeAddr pattern[0], Size)
      s1 += checksum(s)
    let naiveMs = inMilliseconds(getMonoTime() - t0)

    var pool = initPool(byte, Size)
    let t1 = getMonoTime()
    var s2 = 0
    for _ in 0 ..< Iters:
      withBorrow(pool, buf):
        buf.copyFrom(pattern)
        s2 += checksum(buf.toOpenArray())
    let pooledMs = inMilliseconds(getMonoTime() - t1)

    check s1 == s2
    echo "naive=", naiveMs, "ms pooled=", pooledMs, "ms (", Iters, "x", Size, "B)"
