# Examples

Runnable demos. Each prints heap/RSS numbers so you can see reuse working.
Build with `clue`:

```
clue build examples/static_scratch.nim --release --out:/tmp/scratch && /tmp/scratch
clue build examples/pooled_hot_loop.nim --release --out:/tmp/pooled && /tmp/pooled
clue build examples/memfiles_scan.nim --release --out:/tmp/scan && /tmp/scan
clue build examples/buffer_ops.nim --release --out:/tmp/ops && /tmp/ops
clue build examples/rss_benchmark.nim --release --out:/tmp/bench && /tmp/bench
```

Or the same via `nimble` (`nimble c` compiles a single file; `--nimcache`
keeps build artifacts out of the repo):

```
nimble c --nimcache:/tmp/nimcache -d:release --out:/tmp/scratch examples/static_scratch.nim && /tmp/scratch
nimble c --nimcache:/tmp/nimcache -d:release --out:/tmp/pooled examples/pooled_hot_loop.nim && /tmp/pooled
nimble c --nimcache:/tmp/nimcache -d:release --out:/tmp/scan examples/memfiles_scan.nim && /tmp/scan
nimble c --nimcache:/tmp/nimcache -d:release --out:/tmp/ops examples/buffer_ops.nim && /tmp/ops
nimble c --nimcache:/tmp/nimcache -d:release --out:/tmp/bench examples/rss_benchmark.nim && /tmp/bench
```

Binaries go to `/tmp` so the repo stays clean.

| File | What it shows |
| ---- | ------------- |
| `static_scratch.nim` | `buffaloScope` + `StaticBuffer` stack scratch, `reuse` per line. Heap before == heap after. |
| `pooled_hot_loop.nim` | Batching (`seq[seq[byte]]`, O(N) RSS) vs streaming (`initPool` + `withBorrow`, O(1)). Same checksum; retained heap and maxrss side by side. |
| `memfiles_scan.nim` | `memView` zero-copy scan of a 1 MiB mapping vs one `copyFromMemFile` pool. Same checksum, flat heap. |
| `buffer_ops.nim` | B ops: `setLen` (shrink/grow-zero-fill), `pop`, `reserve`, `shrinkToFit`, `maxCap`, `shrinkAfterSpike`, char strings. Prints cap at each step. |
| `rss_benchmark.nim` | Naive (`newSeq` + bulk copy per iter) vs pooled (`copyFrom` into reused backing) at 256 B / 4 KB / 64 KB. Pool grows once from cap 8, then stays flat. |

Memory is read with `system.getOccupiedMem` / `getTotalMem` (heap) and
`posix.getrusage(RUSAGE_SELF)` (process maxrss). Note `ru_maxrss` units
differ by OS (bytes on macOS, KB on Linux); the examples normalize to KB.
