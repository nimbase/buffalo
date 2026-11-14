# Examples

Runnable demos. Each prints heap/RSS numbers so you can see reuse working.
Build with `clue` (see `nim-clue` skill: never raw `nim c` unless asked):

```
clue build examples/static_scratch.nim --release --out:/tmp/scratch && /tmp/scratch
clue build examples/pooled_hot_loop.nim --release --out:/tmp/pooled && /tmp/pooled
clue build examples/memfiles_scan.nim --release --out:/tmp/scan && /tmp/scan
clue build examples/rss_benchmark.nim --release --out:/tmp/bench && /tmp/bench
```

Binaries go to `/tmp` so the repo stays clean.

| File | What it shows |
| ---- | ------------- |
| `static_scratch.nim` | `buffaloScope` + `StaticBuffer` stack scratch, `reuse` per line. Heap before == heap after. |
| `pooled_hot_loop.nim` | Batching (`seq[seq[byte]]`, O(N) RSS) vs streaming (`initPool` + `withBorrow`, O(1)). Same checksum; retained heap and maxrss side by side. |
| `memfiles_scan.nim` | `memView` zero-copy scan of a 1 MiB mapping vs one `copyFromMemFile` pool. Same checksum, flat heap. |
| `rss_benchmark.nim` | Naive (`newSeq` + bulk copy per iter) vs pooled (`copyFrom` into reused backing) at 256 B / 4 KB / 64 KB. Pool grows once from cap 8, then stays flat. |

Memory is read with `system.getOccupiedMem` / `getTotalMem` (heap) and
`posix.getrusage(RUSAGE_SELF)` (process maxrss). Note `ru_maxrss` units
differ by OS (bytes on macOS, KB on Linux); the examples normalize to KB.
