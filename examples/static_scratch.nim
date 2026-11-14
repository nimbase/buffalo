## Static stack scratch with `buffaloScope`.
##
## Run: `clue build examples/static_scratch.nim --release --out:/tmp/scratch`
##
## Shows: a `StaticBuffer` reused across 20k loop iterations allocates
## nothing per iteration. Heap is sampled halfway and at the end: the two
## readings match to within GC bookkeeping noise (tens of bytes), proving
## steady-state zero allocation.

import buffalo

proc parseSum(lines: openArray[string]): int =
  ## Sum integers of the form "id:<n>" using one stack scratch buffer.
  buffaloScope:
    var scratch {.buffalo.}: StaticBuffer[byte, 64]
    for line in lines:
      reuse(scratch):
        scratch.copyFrom(line)
        # Find the digits after ':' without allocating.
        var start = 0
        for i, c in scratch.toOpenArray():
          if c == byte(':'):
            start = i + 1
            break
        var v = 0
        for i in start ..< scratch.len:
          v = v * 10 + (scratch[i] - byte('0')).int
        result += v

let lines = @["id:1", "id:22", "id:303", "id:4040"]

var total = 0
var midHeap = 0
for n in 0 ..< 20_000:
  total += parseSum(lines)
  if n == 9_999:
    GC_fullCollect()
    midHeap = getOccupiedMem()
GC_fullCollect()
let finalHeap = getOccupiedMem()

echo "sum:        ", total # 20_000 * 4366
echo "heap@10k:   ", midHeap, " B"
echo "heap@20k:   ", finalHeap, " B (delta ", finalHeap - midHeap,
  " B over 10k iterations)"
