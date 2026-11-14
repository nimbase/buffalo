import unittest
import std/[os, memfiles]

import buffalo

proc sumBytes(o: openArray[byte]): int =
  for x in o:
    result += x.int

suite "static buffer core":
  test "add, len, cap, clear reuse":
    var sb {.noinit.}: StaticBuffer[byte, 16]
    sb.len = 0
    check sb.cap == 16
    check sb.len == 0
    sb.add(10)
    sb.add(20)
    check sb.len == 2
    check sb[0] == 10
    check sb[1] == 20
    sb.clear()
    check sb.len == 0
    check sb.cap == 16
    sb.add(30)
    check sb.len == 1
    check sb[0] == 30

  test "overflow raises, addUnchecked trusts":
    var sb {.noinit.}: StaticBuffer[byte, 2]
    sb.len = 0
    sb.add(1)
    sb.add(2)
    expect RangeDefect:
      sb.add(3)
    var sb2 {.noinit.}: StaticBuffer[byte, 2]
    sb2.len = 0
    sb2.addUnchecked(7)
    sb2.addUnchecked(8)
    check sb2.len == 2
    check sb2[1] == 8

  test "copyFrom, appendMany, toSeq, toString":
    var sb {.noinit.}: StaticBuffer[byte, 16]
    sb.len = 0
    sb.copyFrom([1'u8, 2, 3])
    check sb.len == 3
    sb.appendMany([4'u8, 5])
    check sb.len == 5
    check sb.toSeq() == @[1'u8, 2, 3, 4, 5]
    check sumBytes(sb.toOpenArray()) == 15
    var st {.noinit.}: StaticBuffer[byte, 16]
    st.len = 0
    st.copyFrom("hi")
    check st.len == 2
    check st.toString() == "hi"

  test "zero policy clears secrets":
    var sb {.noinit.}: StaticBuffer[byte, 8]
    sb.len = 0
    sb.appendMany([9'u8, 9, 9, 9])
    sb.clear(zero = true)
    check sb.len == 0
    check sb.data[0] == 0
    check sb.data[3] == 0
    sb.appendMany([1'u8, 2])
    sb.clear(Retain)
    check sb.len == 0
    sb.appendMany([5'u8])
    sb.clear(Zero)
    check sb.len == 0
    check sb.data[0] == 0

suite "pooled buffer core":
  test "grows once then stable":
    var p = initPool(byte, 4)
    check p.cap == 4
    for i in 0 ..< 100:
      p.clear()
      for j in 0 ..< 10:
        p.add(byte(j))
      check p.len == 10
    check p.cap >= 10
    let stable = p.cap
    for i in 0 ..< 100:
      p.clear()
      for j in 0 ..< 10:
        p.add(byte(j))
    check p.cap == stable

  test "copyFrom replaces, appendMany grows":
    var p = initPool(byte, 2)
    p.copyFrom([1'u8, 2, 3, 4, 5])
    check p.len == 5
    check p.toSeq() == @[1'u8, 2, 3, 4, 5]
    p.copyFrom("ab")
    check p.toString() == "ab"

suite "withBorrow DSL":
  test "resets each entry and aliases pool":
    var pool = initPool(byte, 16)
    for round in 0 ..< 5:
      withBorrow(pool, buf):
        check buf.len == 0
        buf.add(byte(round))
        buf.add(byte(round + 10))
        check buf.len == 2
      check pool.len == 2
    withBorrow(pool, buf):
      check buf.len == 0
      check sumBytes(buf.toOpenArray()) == 0

  test "works for static backing too":
    var sb {.noinit.}: StaticBuffer[byte, 8]
    sb.len = 0
    withBorrow(sb, b):
      b.copyFrom([1'u8, 2, 3])
      check b.len == 3
    check sb.len == 3
    withBorrow(sb, b2):
      check b2.len == 0

  test "sanctioned copy-out via toSeq":
    proc f(): seq[byte] =
      var pool = initPool(byte, 8)
      withBorrow(pool, b):
        b.copyFrom([7'u8, 8])
        result = b.toSeq()
    check f() == @[7'u8, 8]

  test "custom backing via concept":
    type MyBuf = object
      store: array[64, byte]
      len: int
    proc cap(b: MyBuf): int {.inline.} = 64
    proc clear(b: var MyBuf) {.inline.} = b.len = 0
    proc add(b: var MyBuf, v: byte) {.inline.} =
      b.store[b.len] = v
      inc b.len
    var m: MyBuf
    m.len = 0
    withBorrow(m, b):
      b.add(42)
      check b.len == 1
      check b.cap == 64
    check m.len == 1

suite "buffaloScope pragma":
  test "pragma scratch reuses without alloc":
    proc run(): seq[byte] =
      buffaloScope:
        var scratch {.buffalo.}: StaticBuffer[byte, 256]
        check scratch.len == 0
        check scratch.cap == 256
        scratch.copyFrom("hello")
        check scratch.len == 5
        for i in 0 ..< 10:
          reuse(scratch):
            scratch.add(byte(i))
            check scratch.len == 1
        scratch.clear()
        scratch.copyFrom("done")
        result = scratch.toSeq()
    check run() == cast[seq[byte]]("done")

  test "plain vars alongside pragma vars keep order":
    buffaloScope:
      var plain = 41
      var scratch {.buffalo.}: StaticBuffer[byte, 16]
      plain += 1
      scratch.add(1)
      check plain == 42
      check scratch.len == 1

suite "buffer ops (B)":
  test "setLen shrink and grow":
    var sb {.noinit.}: StaticBuffer[byte, 8]
    sb.len = 0
    sb.appendMany([1'u8, 2, 3, 4])
    sb.setLen(2)
    check sb.len == 2
    check sb.toSeq() == @[1'u8, 2]
    sb.setLen(4) # regrow zero-fills, safe on noinit scratch
    check sb.len == 4
    check sb[2] == 0
    check sb[3] == 0
    expect RangeDefect:
      sb.setLen(9)
    expect RangeDefect:
      sb.setLen(-1)
    var p = initPool(byte, 4)
    p.copyFrom([1'u8, 2])
    p.setLen(6) # grows backing, zero-fills
    check p.len == 6
    check p[2] == 0
    check p.toSeq() == @[1'u8, 2, 0, 0, 0, 0]
    p.setLen(1)
    check p.len == 1
    expect RangeDefect:
      p.setLen(-1)

  test "pop returns last, empty raises":
    var sb {.noinit.}: StaticBuffer[byte, 4]
    sb.len = 0
    sb.appendMany([5'u8, 6, 7])
    check sb.pop() == 7
    check sb.pop() == 6
    check sb.len == 1
    expect RangeDefect:
      var e {.noinit.}: StaticBuffer[byte, 2]
      e.len = 0
      discard e.pop()
    var p = initPool(byte, 4)
    p.copyFrom([8'u8, 9])
    check p.pop() == 9
    check p.len == 1
    expect RangeDefect:
      var q = initPool(byte, 2)
      discard q.pop()

  test "reserve and ensureUnused":
    var p = initPool(byte, 2)
    p.reserve(64)
    check p.cap >= 64
    check p.len == 0
    p.ensureUnused(16)
    check p.cap >= 16
    var sb {.noinit.}: StaticBuffer[byte, 8]
    sb.len = 0
    sb.reserve(8) # check only, no-op within Cap
    sb.ensureUnused(8)
    expect RangeDefect:
      sb.reserve(9)
    sb.appendMany([1'u8, 2, 3])
    expect RangeDefect:
      sb.ensureUnused(6) # 3 + 6 > 8
    expect RangeDefect:
      p.reserve(-1)
    expect RangeDefect:
      p.ensureUnused(-1)

  test "shrinkToFit releases excess":
    var p = initPool(byte, 64)
    p.copyFrom([1'u8, 2, 3])
    check p.cap == 64
    p.shrinkToFit()
    check p.cap == 3
    check p.toSeq() == @[1'u8, 2, 3]
    p.clear()
    p.shrinkToFit()
    check p.cap == 0
    var sb {.noinit.}: StaticBuffer[byte, 8]
    sb.len = 0
    sb.shrinkToFit() # no-op for fixed storage

  test "maxCap bounds growth":
    var p = initPool(byte, 4, maxCap = 8)
    check p.maxCap == 8
    p.copyFrom([1'u8, 2, 3, 4, 5, 6, 7, 8])
    check p.len == 8
    expect RangeDefect:
      p.add(9)
    expect RangeDefect:
      p.copyFrom([1'u8, 2, 3, 4, 5, 6, 7, 8, 9])
    var q = initPool(byte, 16)
    q.copyFrom([1'u8, 2, 3, 4])
    expect RangeDefect:
      q.setMaxCap(3) # below used length
    q.setMaxCap(8)
    check q.maxCap == 8
    check q.cap == 8 # backing shrunk immediately
    check q.toSeq() == @[1'u8, 2, 3, 4]
    q.setMaxCap(0) # remove cap
    q.appendMany([5'u8, 6, 7, 8, 9, 10])
    check q.len == 10

  test "shrinkAfterSpike keeps steady working set":
    var p = initPool(byte, 8)
    p.copyFrom(newSeq[byte](1024))
    check p.cap >= 1024
    p.clear()
    p.appendMany([1'u8, 2])
    p.shrinkAfterSpike(16)
    check p.cap == 16
    check p.toSeq() == @[1'u8, 2]
    # steady below len keeps len
    p.shrinkAfterSpike(0)
    check p.cap == 2

  test "char buffers accept strings":
    var csb {.noinit.}: StaticBuffer[char, 8]
    csb.len = 0
    csb.copyFrom("hi")
    check csb.len == 2
    check csb.toString() == "hi"
    csb.appendMany("!")
    check csb.toString() == "hi!"
    expect RangeDefect:
      csb.copyFrom("toolong!!")
    # PooledBuffer[char] via the generic openArray overloads
    var p = initPool(char, 4)
    p.copyFrom("ab")
    check p.toString() == "ab"
    p.appendMany("cd")
    check p.toString() == "abcd"
    p.setLen(1)
    check p.toString() == "a"
    check p.pop() == 'a'

suite "views and memfiles":
  test "toOpenArray is zero-copy view":
    var sb {.noinit.}: StaticBuffer[byte, 8]
    sb.len = 0
    sb.appendMany([1'u8, 2, 3])
    check sumBytes(sb.toOpenArray()) == 6

  test "memfiles view and bulk copy":
    let dir = getTempDir()
    let path = dir / "buffalo_probe.bin"
    writeFile(path, "hello-memfile")
    try:
      var mf = memfiles.open(path, fmRead)
      try:
        check mf.size == 13
        check sumBytes(memView(mf)) == sumBytes(cast[seq[byte]]("hello-memfile"))
        var sb {.noinit.}: StaticBuffer[byte, 64]
        sb.len = 0
        sb.copyFromMemFile(mf)
        check sb.len == 13
        check sb.toString() == "hello-memfile"
        var p = initPool(byte, 2)
        p.copyFromMemFile(mf)
        check p.toString() == "hello-memfile"
        var first = true
        for slice in memSlices(mf):
          if first:
            var sb2 {.noinit.}: StaticBuffer[byte, 64]
            sb2.len = 0
            sb2.copyFromSlice(slice)
            check sb2.len == slice.size
            check sumBytes(sb2.toOpenArray()) == sumBytes(sliceView(slice))
            first = false
      finally:
        mf.close()
    finally:
      removeFile(path)

suite "memfiles chunks and ranges":
  test "memChunks strides fixed windows":
    let dir = getTempDir()
    let path = dir / "buffalo_chunks.bin"
    var content = newString(10)
    for i in 0 ..< 10:
      content[i] = char(i)
    writeFile(path, content)
    try:
      var mf = memfiles.open(path, fmRead)
      try:
        var sizes: seq[int] = @[]
        var bytes: seq[byte] = @[]
        for slice in memChunks(mf, 4):
          sizes.add(slice.size)
          for b in sliceView(slice):
            bytes.add(b)
        check sizes == @[4, 4, 2]
        check bytes == cast[seq[byte]](content)
        var single: seq[int] = @[]
        for slice in memChunks(mf, 64):
          single.add(slice.size)
        check single == @[10]
      finally:
        mf.close()
    finally:
      removeFile(path)

  test "copyFromMemFile offset and len":
    let dir = getTempDir()
    let path = dir / "buffalo_range.bin"
    writeFile(path, "0123456789")
    try:
      var mf = memfiles.open(path, fmRead)
      try:
        var sb {.noinit.}: StaticBuffer[byte, 8]
        sb.len = 0
        sb.copyFromMemFile(mf, 2, 4)
        check sb.len == 4
        check sb.toString() == "2345"
        sb.copyFromMemFile(mf, 0, 0)
        check sb.len == 0
        expect RangeDefect:
          sb.copyFromMemFile(mf, 8, 4) # past end of mapping
        expect RangeDefect:
          sb.copyFromMemFile(mf, 0, 9) # past capacity
        expect RangeDefect:
          sb.copyFromMemFile(mf, -1, 2)
        var p = initPool(byte, 2)
        p.copyFromMemFile(mf, 5, 5)
        check p.toString() == "56789"
        expect RangeDefect:
          p.copyFromMemFile(mf, 9, 2)
      finally:
        mf.close()
    finally:
      removeFile(path)

suite "memfiles writable":
  test "copyToMemFile whole mapping round-trip":
    let dir = getTempDir()
    let path = dir / "buffalo_writeback.bin"
    writeFile(path, "0123456789")
    try:
      var mf = memfiles.open(path, fmReadWrite)
      try:
        var sb {.noinit.}: StaticBuffer[byte, 16]
        sb.len = 0
        sb.copyFrom("HELLO")
        let sizeBefore = mf.size
        sb.copyToMemFile(mf)
        check mf.size == sizeBefore
        check sb.len == 5 # write preserves buffer len
        check sb.toString() == "HELLO"
        # read back through the same mapping
        var back {.noinit.}: StaticBuffer[byte, 16]
        back.len = 0
        back.copyFromMemFile(mf, 0, 5)
        check back.toString() == "HELLO"
        mf.flush()
      finally:
        mf.close()
      # durable on disk after close
      check readFile(path)[0 ..< 5] == "HELLO"
    finally:
      removeFile(path)

  test "copyToMemFile offset and len":
    let dir = getTempDir()
    let path = dir / "buffalo_write_range.bin"
    writeFile(path, "0123456789")
    try:
      var mf = memfiles.open(path, fmReadWrite)
      try:
        var p = initPool(byte, 8)
        p.copyFrom("abcd")
        p.copyToMemFile(mf, 2, 4) # mapping becomes 01abcd6789
        check p.len == 4
        check mf.size == 10
        var back = initPool(byte, 10)
        back.copyFromMemFile(mf)
        check back.toString() == "01abcd6789"
        # zero-len write is a no-op but still range-checked
        p.copyToMemFile(mf, 10, 0)
        expect RangeDefect:
          p.copyToMemFile(mf, 11, 0) # offset past end
        expect RangeDefect:
          p.copyToMemFile(mf, 9, 2) # past end of mapping
        expect RangeDefect:
          p.copyToMemFile(mf, 0, 5) # len exceeds buffer used prefix
        expect RangeDefect:
          p.copyToMemFile(mf, -1, 2)
        mf.flush()
      finally:
        mf.close()
      check readFile(path) == "01abcd6789"
    finally:
      removeFile(path)

  test "copyToSlice writes chunk windows":
    let dir = getTempDir()
    let path = dir / "buffalo_write_chunks.bin"
    writeFile(path, "........")
    try:
      var mf = memfiles.open(path, fmReadWrite)
      try:
        var pool = initPool(byte, 4)
        var idx = 0
        for slice in memChunks(mf, 4):
          pool.copyFrom(if idx == 0: "AB" else: "CDEF")
          # first window is 4 wide but we only write 2 bytes of it
          let n = if idx == 0: 2 else: 4
          pool.copyToMemFile(mf, idx * 4, n)
          inc idx
        mf.flush()
        var back = initPool(byte, 8)
        back.copyFromMemFile(mf)
        check back.toString() == "AB..CDEF"
        # whole-slice write + overflow
        for slice in memChunks(mf, 8):
          var sb {.noinit.}: StaticBuffer[byte, 8]
          sb.len = 0
          sb.copyFrom("ZZZZZZZZ")
          sb.copyToSlice(slice)
          check sumBytes(sliceView(slice)) == sumBytes(sb.toOpenArray())
          var big {.noinit.}: StaticBuffer[byte, 16]
          big.len = 0
          big.copyFrom("ZZZZZZZZ!")
          expect RangeDefect:
            big.copyToSlice(slice)
        mf.flush()
      finally:
        mf.close()
    finally:
      removeFile(path)

  test "repeated copyTo does not grow":
    let dir = getTempDir()
    let path = dir / "buffalo_write_flat.bin"
    writeFile(path, "0123456789")
    try:
      var mf = memfiles.open(path, fmReadWrite)
      try:
        var p = initPool(byte, 10)
        p.copyFrom("0123456789")
        let capBefore = p.cap
        for _ in 0 ..< 100:
          p.copyToMemFile(mf)
          p.copyToMemFile(mf, 0, 10)
          for slice in memChunks(mf, 4):
            var sb {.noinit.}: StaticBuffer[byte, 4]
            sb.len = 0
            sb.copyFromSlice(slice)
            sb.copyToSlice(slice)
        check p.cap == capBefore
        check p.len == 10
        check mf.size == 10
        var back = initPool(byte, 10)
        back.copyFromMemFile(mf)
        check back.toString() == "0123456789"
      finally:
        mf.close()
    finally:
      removeFile(path)

suite "ensureLen without fill":
  test "pooled grows backing, keeps content":
    var p = initPool(byte, 4)
    p.copyFrom([1'u8, 2])
    p.ensureLen(10)
    check p.len == 10
    check p.cap >= 10
    check p[0] == 1 and p[1] == 2
    # steady state: no regrowth
    let cap = p.cap
    for _ in 0 ..< 50:
      p.clear()
      p.ensureLen(10)
    check p.cap == cap
    expect RangeDefect:
      p.ensureLen(-1)

  test "static checks capacity, keeps content":
    var sb {.noinit.}: StaticBuffer[byte, 8]
    sb.len = 0
    sb.appendMany([7'u8, 8])
    sb.ensureLen(5)
    check sb.len == 5
    check sb[0] == 7 and sb[1] == 8
    expect RangeDefect:
      sb.ensureLen(9)
    expect RangeDefect:
      sb.ensureLen(-1)

suite "withBorrows multi-pool":
  test "clears all pools and aliases all names":
    var pa = initPool(byte, 8)
    var pb = initPool(byte, 8)
    for round in 0 ..< 5:
      withBorrows(pa, a, pb, b):
        check a.len == 0
        check b.len == 0
        a.copyFrom([byte(round)])
        b.copyFrom([byte(round + 10)])
        check a.len == 1
        check b.len == 1
      check pa.len == 1
      check pb.len == 1
    # values survive between borrows; a fresh borrow clears again
    check pa.toSeq() == @[4'u8]
    check pb.toSeq() == @[14'u8]
    withBorrows(pa, a, pb, b):
      check a.len == 0
      check b.len == 0

  test "three pools in one block":
    var p1 = initPool(byte, 4)
    var p2 = initPool(byte, 4)
    var p3 = initPool(byte, 4)
    withBorrows(p1, a, p2, b, p3, c):
      a.copyFrom("x")
      b.copyFrom("yy")
      c.copyFrom("zzz")
    check p1.toString() == "x"
    check p2.toString() == "yy"
    check p3.toString() == "zzz"

  test "generic call args allowed, header alias bound by withBorrow rules":
    var pa = initPool(byte, 8)
    var total = 0
    withBorrows(pa, a):
      a.copyFrom([1'u8, 2, 3])
      total = sumBytes(a.toOpenArray())
    check total == 6

suite "blit bulk copy":
  test "copies seq into array and pool backing":
    var dstArr: array[6, byte]
    blit(dstArr, [1'u8, 2, 3])
    check dstArr[0 ..< 3] == [1'u8, 2, 3]
    var p = initPool(byte, 8)
    p.setLen(6)
    blit(p.data.toOpenArray(2, 5), [9'u8, 8, 7, 6])
    check p.data[2 ..< 6] == @[9'u8, 8, 7, 6]
    expect RangeDefect:
      blit(dstArr.toOpenArray(0, 1), [1'u8, 2, 3])
    # empty blit is a no-op
    var empty: array[2, byte] = [0, 0]
    blit(empty, newSeq[byte]())
    check empty == [0'u8, 0]
