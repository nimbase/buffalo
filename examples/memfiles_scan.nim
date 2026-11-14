## Minimal-RSS scan of a memory-mapped file.
##
## Run: `clue build examples/memfiles_scan.nim --release --out:/tmp/scan`
##
## Shows three ways to checksum a 200 MiB file and what each costs in RSS:
## - `memView`: zero-copy view over the mapping. RSS ~= the mapping itself.
## - chunked pool: stride the mapping in 10 MiB windows through one reused
##   pool. RSS ~= mapping + 10 MiB, no 2x copy.
## - streamed: plain `FileStream` reads into one reused `StaticBuffer`,
##   no mapping at all. RSS ~= 10 MiB. Minimal.
## All three checksums must agree. maxrss is sampled after each phase.

import std/[memfiles, monotimes, times, os, posix]
import buffalo

const FileSize = 200 * 1024 * 1024
const Passes = 5
const Chunk = 10 * 1024 * 1024

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

let path = getTempDir() / "buffalo_scan_demo.bin"
# Deterministic payload, written in 1 MiB pieces to keep setup memory low
# regardless of the processing chunk size.
if not fileExists(path):
  block:
    var piece = newString(1024 * 1024)
    for i in 0 ..< piece.len:
      piece[i] = char(i and 0xFF)
    var s = syncio.open(path, fmWrite)
    for _ in 0 ..< FileSize div piece.len:
      s.write(piece)
    s.close()

var mf = memfiles.open(path, fmRead, mappedSize = -1)
var rssView, rssChunked, rssStreamed: int64
var sumView, sumChunked, sumStreamed: int
try:
  # Streamed first: maxrss is a high-water mark, so the minimal path
  # must run before anything maps the file.
  # No mapping: stream 10 MiB reads into one reused stack buffer.
  # Manual `{.noinit.}` instead of `buffaloScope` here: filling via
  # `readBuffer` needs `addr` for the read call, which the DSL deliberately
  # forbids. The pointer never leaves the loop iteration.
  let t2 = getMonoTime()
  var scratch {.noinit.}: StaticBuffer[byte, Chunk]
  scratch.len = 0
  var f = syncio.open(path)
  for _ in 0 ..< Passes:
    f.setFilePos(0)
    while true:
      let n = f.readBuffer(addr scratch.data[0], Chunk)
      if n <= 0:
        break
      scratch.len = n # bytes just read are now the used prefix
      sumStreamed += checksum(scratch.toOpenArray())
  f.close()
  let msStreamed = inMilliseconds(getMonoTime() - t2)
  rssStreamed = maxRssKb()

  let t0 = getMonoTime()
  for _ in 0 ..< Passes:
    sumView += checksum(memView(mf)) # zero-copy view over the mapping
  let msView = inMilliseconds(getMonoTime() - t0)
  rssView = maxRssKb()

  # Stride the mapping in fixed windows through one reused pool.
  var pool = initPool(byte, Chunk)
  let t1 = getMonoTime()
  for _ in 0 ..< Passes:
    for slice in memChunks(mf, Chunk):
      withBorrow(pool, buf):
        buf.copyFromSlice(slice)
        sumChunked += checksum(buf.toOpenArray())
  let msChunked = inMilliseconds(getMonoTime() - t1)
  rssChunked = maxRssKb()

  doAssert sumView == sumChunked and sumChunked == sumStreamed

  echo "file:     ", mf.size, " B x ", Passes, " passes"
  echo "streamed: sum=", sumStreamed, " time=", msStreamed,
    " ms maxrss=", rssStreamed, " KB (no mapping, 10 MiB stack)"
  echo "memView:  sum=", sumView, " time=", msView,
    " ms maxrss=", rssView, " KB (mapping only)"
  echo "chunked:  sum=", sumChunked, " time=", msChunked,
    " ms maxrss=", rssChunked, " KB (mapping + 10 MiB pool)"
finally:
  mf.close()
  # removeFile(path)
