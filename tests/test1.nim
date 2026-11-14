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
