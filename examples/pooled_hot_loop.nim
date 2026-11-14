## Batching vs streaming: the RSS case for buffer reuse.
##
## Run: `clue build examples/pooled_hot_loop.nim --release --out:/tmp/pooled`
##
## Scenario: 50k chunks of 256 B arrive and each must be checksummed.
## - batching (naive): keep every chunk in a `seq[seq[byte]]`, sum at the end.
##   Memory grows with the input: O(N).
## - streaming (buffalo): borrow one pooled buffer per chunk, fold the
##   checksum on the fly. Memory stays flat: O(1).
## Both produce the same checksum; only the memory profile differs.

import std/[monotimes, times, posix]
import buffalo

const Iters = 50_000
const Payload = 256

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

proc runBatched(): tuple[sum: int, ms: int64, heap: int] =
  ## Keep everything, then process. Simple, but RSS grows with input.
  var kept: seq[seq[byte]] = @[]
  let t0 = getMonoTime()
  for n in 0 ..< Iters:
    var s = newSeq[byte](Payload)
    for i in 0 ..< Payload:
      s[i] = byte((i + n) and 0xFF)
    kept.add(move(s))
  for s in kept:
    result.sum += checksum(s)
  result.ms = inMilliseconds(getMonoTime() - t0)
  GC_fullCollect()
  result.heap = getOccupiedMem()

proc runStreamed(): tuple[sum: int, ms: int64, heap: int, cap: int] =
  ## One pool borrowed per chunk; only the checksum survives the iteration.
  var pool = initPool(byte, Payload) # allocated once, outside the loop
  let t0 = getMonoTime()
  for n in 0 ..< Iters:
    withBorrow(pool, buf):
      for i in 0 ..< Payload:
        buf.add(byte((i + n) and 0xFF))
      result.sum += checksum(buf.toOpenArray())
  result.ms = inMilliseconds(getMonoTime() - t0)
  result.cap = pool.cap
  GC_fullCollect()
  result.heap = getOccupiedMem()

let batched = runBatched()
let rssAfterBatch = maxRssKb()
GC_fullCollect()
let streamed = runStreamed()
doAssert batched.sum == streamed.sum, "both paths must agree"

echo "chunks: ", Iters, " x ", Payload, " B (checksum ", batched.sum, ")"
echo "batched (retain all): sum folded at end, time=", batched.ms,
  " ms heap=", batched.heap, " B maxrss=", rssAfterBatch, " KB"
echo "streamed (buffalo):   O(1) pool cap=", streamed.cap,
  " B, time=", streamed.ms, " ms heap=", streamed.heap, " B"
echo "maxrss end: ", maxRssKb(), " KB (high-water mark, set by batching)"
