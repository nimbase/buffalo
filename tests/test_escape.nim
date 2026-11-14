import unittest
import std/[os, osproc, strutils, streams]

import buffalo

proc sumBytes(o: openArray[byte]): int =
  for x in o:
    result += x.int

proc srcDir(): string =
  currentSourcePath().parentDir() / ".." / "src"

var negCounter = 0

proc mustFail(name, code: string) =
  ## Compile `code` in a subprocess; assert it fails with a buffalo error.
  ## Uses an argv list (no shell), so quoting is correct on every OS.
  inc negCounter
  let path = getTempDir() / ("buffalo_neg_" & name & ".nim")
  writeFile(path, code)
  let nimExe = findExe("nim")
  check nimExe.len > 0
  var p = startProcess(nimExe,
    args = ["c", "--hints:off", "--path:" & srcDir(), path],
    options = {poStdErrToStdOut})
  let outp = p.outputStream.readAll()
  let exitc = p.waitForExit()
  p.close()
  check exitc != 0
  check outp.contains("buffalo: '" ) or outp.contains("buffalo: {.")
  if exitc == 0 or not outp.contains("buffalo"):
    echo "--- unexpected compile output for " & name & " ---"
    echo outp

suite "escape checks (compile-fail)":
  test "outer store rejected":
    mustFail("outer_store",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "var outer = initPool(byte, 8)\n" &
      "withBorrow(pool, b):\n" &
      "  b.add(1)\n" &
      "  outer = b\n")

  test "var bind rejected":
    mustFail("var_bind",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "withBorrow(pool, b):\n" &
      "  b.add(1)\n" &
      "  var leaked = b\n" &
      "  echo leaked.len\n")

  test "addr without parens rejected":
    mustFail("addr_cmd",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "var p: ptr byte = nil\n" &
      "withBorrow(pool, b):\n" &
      "  b.add(1)\n" &
      "  p = addr b[0]\n")

  test "addr with parens rejected":
    mustFail("addr_call",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "var p: ptr byte = nil\n" &
      "withBorrow(pool, b):\n" &
      "  b.add(1)\n" &
      "  p = addr(b[0])\n")

  test "unsafeAddr rejected":
    mustFail("unsafeaddr",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "withBorrow(pool, b):\n" &
      "  b.add(1)\n" &
      "  var p = unsafeAddr b.data[0]\n" &
      "  echo p.repr\n")

  test "return borrow rejected":
    mustFail("return_borrow",
      "import buffalo\n" &
      "proc f(): auto =\n" &
      "  var pool = initPool(byte, 8)\n" &
      "  withBorrow(pool, b):\n" &
      "    b.add(1)\n" &
      "    return b\n")

  test "result borrow rejected":
    mustFail("result_borrow",
      "import buffalo\n" &
      "import buffalo\n" &
      "proc f(): PooledBuffer[byte] =\n" &
      "  var pool = initPool(byte, 8)\n" &
      "  withBorrow(pool, b):\n" &
      "    b.add(1)\n" &
      "    result = b\n")

  test "closure capture rejected":
    mustFail("closure",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "withBorrow(pool, b):\n" &
      "  b.add(1)\n" &
      "  let fn = proc(): int = b.len\n" &
      "  echo fn()\n")

  test "backing array store rejected":
    mustFail("backing_store",
      "import buffalo\n" &
      "var sb: StaticBuffer[byte, 8]\n" &
      "sb.len = 0\n" &
      "var outerArr: array[8, byte]\n" &
      "withBorrow(sb, b):\n" &
      "  b.add(1)\n" &
      "  outerArr = b.data\n")

  test "buffaloScope let rejected":
    mustFail("scope_let",
      "import buffalo\n" &
      "buffaloScope:\n" &
      "  let x {.buffalo.}: StaticBuffer[byte, 8]\n" &
      "  echo x.len\n")

  test "buffaloScope colon form rejected":
    mustFail("scope_colon",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "buffaloScope:\n" &
      "  var x {.buffalo: pool.}: StaticBuffer[byte, 8]\n" &
      "  echo x.len\n")

  test "buffaloScope nested routine rejected":
    mustFail("scope_nested_routine",
      "import buffalo\n" &
      "buffaloScope:\n" &
      "  proc foo() =\n" &
      "    var x {.buffalo.}: StaticBuffer[byte, 8]\n" &
      "    echo x.len\n")

suite "escape checks (allowed uses)":
  test "scalar len/cap/element copies allowed":
    var pool = initPool(byte, 8)
    var outLen = 0
    withBorrow(pool, b):
      b.copyFrom([9'u8, 9])
      outLen = b.len
    check outLen == 2
    var e: byte = 0
    withBorrow(pool, b):
      e = b[0]
    check e == 9
    proc getLen(): int =
      var p2 = initPool(byte, 8)
      withBorrow(p2, b):
        b.copyFrom([1'u8, 2, 3])
        return b.len
      return -1
    check getLen() == 3
    proc sumIt(): int =
      var p3 = initPool(byte, 8)
      withBorrow(p3, b):
        b.copyFrom([1'u8, 2, 3])
        return sumBytes(b.toOpenArray())
      return -1
    check sumIt() == 6

  test "sanctioned copies allowed":
    proc f(): seq[byte] =
      var pool = initPool(byte, 8)
      withBorrow(pool, b):
        b.copyFrom([7'u8, 8])
        result = b.toSeq()
    check f() == @[7'u8, 8]
    var pool = initPool(byte, 8)
    var outer: seq[byte] = @[]
    withBorrow(pool, b):
      b.copyFrom([1'u8])
      outer = b.toSeq()
    check outer == @[1'u8]

suite "buffaloScope nesting":
  test "block/if/for nested decls reuse":
    buffaloScope:
      block:
        var inner {.buffalo.}: StaticBuffer[byte, 16]
        check inner.len == 0
        inner.copyFrom("hi")
        check inner.toString() == "hi"
      if true:
        var condBuf {.buffalo.}: StaticBuffer[byte, 16]
        condBuf.copyFrom("yo")
        check condBuf.toString() == "yo"
      else:
        check true
      for i in 0 ..< 3:
        var loopBuf {.buffalo.}: StaticBuffer[byte, 8]
        loopBuf.clear()
        loopBuf.add(byte(i))
        check loopBuf.len == 1
        check loopBuf[0] == byte(i)

  test "nested buffaloScope keeps order with plain vars":
    buffaloScope:
      var n = 0
      block:
        var scratch {.buffalo.}: StaticBuffer[byte, 8]
        scratch.add(5)
        n = scratch.len
      check n == 1

suite "withBorrows checks":
  test "odd arg count rejected":
    mustFail("borrows_odd",
      "import buffalo\n" &
      "var pool = initPool(byte, 8)\n" &
      "withBorrows(pool):\n" &
      "  echo 1\n")

  test "escape through one name rejected":
    mustFail("borrows_escape",
      "import buffalo\n" &
      "var pa = initPool(byte, 8)\n" &
      "var pb = initPool(byte, 8)\n" &
      "withBorrows(pa, a, pb, b):\n" &
      "  a.add(1)\n" &
      "  b.add(2)\n" &
      "  var leaked = b\n" &
      "  echo leaked.len\n")
