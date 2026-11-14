## Zero-copy scan of a memory-mapped file.
##
## Run: `clue build examples/memfiles_scan.nim --release --out:/tmp/scan`
##
## Shows: `memView` scans the mapping in place (no copy, flat RSS), while
## `copyFromMemFile` pulls the bytes into a reusable pool exactly once.

import std/[memfiles, monotimes, times, os, posix]
import buffalo

proc maxRssKb(): int64 =
  var ru: Rusage
  discard getrusage(RUSAGE_SELF, addr ru)
  when defined(macosx):
    ru.ru_maxrss div 1024
  else:
    ru.ru_maxrss

proc checksum(o: openArray[byte]): int =
  for b in o:
    result += b.int

let path = getTempDir() / "buffalo_scan_demo.bin"
# Deterministic 1 MiB payload so the demo is self-contained.
block:
  var content = newString(1024 * 1024)
  for i in 0 ..< content.len:
    content[i] = char(i and 0xFF)
  writeFile(path, content)

var mf = memfiles.open(path, fmRead, mappedSize = -1)
try:
  GC_fullCollect()
  let heapBefore = getOccupiedMem()

  let t0 = getMonoTime()
  var direct = 0
  for _ in 0 ..< 20:
    direct += checksum(memView(mf)) # zero-copy view over the mapping
  let directMs = inMilliseconds(getMonoTime() - t0)

  let t1 = getMonoTime()
  var pool = initPool(byte, mf.size) # one backing store for the whole demo
  var copied = 0
  for _ in 0 ..< 20:
    withBorrow(pool, buf):
      buf.copyFromMemFile(mf)       # single bulk copy into reused memory
      copied += checksum(buf.toOpenArray())
  let copiedMs = inMilliseconds(getMonoTime() - t1)

  doAssert direct == copied, "both paths must agree"
  GC_fullCollect()

  echo "file:    ", mf.size, " B x 20 passes"
  echo "memView: sum=", direct, " time=", directMs, " ms (no copy)"
  echo "pool:    sum=", copied, " time=", copiedMs, " ms (one backing store)"
  echo "heap:    before=", heapBefore, " B after=", getOccupiedMem(),
    " B (after = the 1 MiB pool itself, allocated once)"
  echo "maxrss:  ", maxRssKb(), " KB"
finally:
  mf.close()
  removeFile(path)
