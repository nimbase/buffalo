## Scaling benchmark: one pool, several payload sizes.
##
## Run: `clue build examples/rss_benchmark.nim --release --out:/tmp/bench`
##
## Shows per payload size: naive (`newSeq` per iteration) vs pooled
## (`initPool(byte, 8)` once, borrowed per iteration). The pool grows on the
## first pass, then stays flat on the second pass while the checksum stays
## identical. Memory numbers are printed, not asserted, since exact figures
## depend on the allocator and `--mm` setting.

import std/[monotimes, times, posix]
import buffalo

const Iters = 1_000

proc maxRssKb(): int64 =
  var ru: Rusage
  discard getrusage(RUSAGE_SELF, addr ru)
  when defined(macosx):
    ru.ru_maxrss div 1024 # macOS reports bytes, Linux reports KB
  else:
    ru.ru_maxrss

proc checksum(o: openArray[byte]): int =
  for b in o:
    result += b.int

proc benchNaive(size: int, pattern: openArray[byte]): tuple[sum: int,
    ms: int64] =
  let t0 = getMonoTime()
  for _ in 0 ..< Iters:
    var s = newSeq[byte](size) # fresh backing store every iteration
    if size > 0:
      copyMem(addr s[0], unsafeAddr pattern[0], size)
    result.sum += checksum(s)
  result.ms = inMilliseconds(getMonoTime() - t0)

proc benchPooled(size: int, pattern: openArray[byte]): tuple[sum: int,
    ms: int64, cap: int] =
  ## Start tiny on purpose: the first pass grows the pool, the second
  ## pass must not grow it again.
  var pool = initPool(byte, 8)
  for pass in 0 ..< 2:
    let t0 = getMonoTime()
    var passSum = 0
    for _ in 0 ..< Iters:
      withBorrow(pool, buf):
        buf.copyFrom(pattern) # bulk copy into the reused backing store
        passSum += checksum(buf.toOpenArray())
    if pass == 0:
      result.sum = passSum
      result.ms = inMilliseconds(getMonoTime() - t0)
    else:
      doAssert passSum == result.sum, "both passes must agree"
  result.cap = pool.cap
  doAssert pool.cap >= size, "pool must fit the payload"

proc makePattern(size: int): seq[byte] =
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = byte((i * 31) and 0xFF)

let pat256 = makePattern(256)
let naive256 = benchNaive(256, pat256)
let pooled256 = benchPooled(256, pat256)
doAssert naive256.sum == pooled256.sum
let pat4k = makePattern(4096)
let naive4k = benchNaive(4096, pat4k)
let pooled4k = benchPooled(4096, pat4k)
doAssert naive4k.sum == pooled4k.sum
let pat64k = makePattern(65536)
let naive64k = benchNaive(65536, pat64k)
let pooled64k = benchPooled(65536, pat64k)
doAssert naive64k.sum == pooled64k.sum

GC_fullCollect()
echo "iters: ", Iters, " per size"
echo "size      naive(ms)  pooled(ms)  poolCap(B)"
echo "256 B     ", naive256.ms, "        ", pooled256.ms, "         ",
  pooled256.cap
echo "4 KB      ", naive4k.ms, "        ", pooled4k.ms, "         ",
  pooled4k.cap
echo "64 KB     ", naive64k.ms, "       ", pooled64k.ms, "         ",
  pooled64k.cap
echo "heap after full collect: ", getOccupiedMem(), " B"
echo "maxrss: ", maxRssKb(), " KB"
