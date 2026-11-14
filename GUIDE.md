# buffalo guide

How to pick a buffer, reuse it correctly, and stay allocation-free.

## Which buffer to pick

| Situation | Pick | Why |
| --------- | ---- | --- |
| Fixed-size scratch: line buffers, parsers, encoders, protocol frames | `StaticBuffer[T, Cap]` on the stack | Never allocates. `cap` is a compile-time constant. |
| Variable-size work: chunks, payloads, mapped regions | `PooledBuffer[T]` via `initPool` | Backing allocated once, grows geometrically, then stays flat. |
| Need the result to outlive the loop | Neither: copy out | Buffers are borrowed. Keep data with `toSeq` / `toString`. |

`T` should be a plain value type (`byte`, `char`, numbers) for true zero
cost. Types with destructors work but pay cleanup at scope exit.

## The borrow rule

A borrowed buffer must not outlive its scope. The compiler enforces this
at macro-expansion time:

- no `return buf`, no `result = buf`
- no `outer = buf`, no `var x = buf`
- no `addr buf[0]` / `unsafeAddr ...`
- no capture by a nested `proc` / `func` / `iterator` / `lambda` / `do`

These stay allowed: `buf.len`, `buf.cap`, `buf[i]` copies,
`handle(buf.toOpenArray())` as an immediate argument, and explicit
copy-out with `toSeq` / `toString`. `return buf.len` and
`return sum(buf.toOpenArray())` are fine: they return computed values,
not the buffer.

When a check fires, the fix is almost always one of: use the buffer
directly inside the scope, or copy out what you need to keep.

## Patterns

### Hot loop with a pool

Allocate once, borrow per iteration. The pool stays flat after warmup.

```nim
import buffalo

var pool = initPool(byte, 4096) # once, outside the loop
for chunk in incoming:
  withBorrow(pool, buf):
    buf.copyFrom(chunk)
    handle(buf.toOpenArray()) # zero-copy view, used immediately
```

### Stack scratch with the pragma

For short-lived scratch inside one procedure. `buffaloScope` strips
`{.buffalo.}`, skips zero-init for POD statics, and injects `clear()`.

```nim
import buffalo

proc parse(line: string): int =
  buffaloScope:
    var scratch {.buffalo.}: StaticBuffer[byte, 256]
    scratch.copyFrom(line)
    # ... work on scratch.toOpenArray() ...
    result = checksum(scratch.toOpenArray()) # computed value, allowed
```

`reuse(scratch): ...` clears an existing buffer for another pass in the
same scope. `{.buffalo.}` works in nested `block:` / `if:` / loops, but
not inside nested routines (give those their own `buffaloScope`).

### Cross-call pools

Promote the pool to module scope when many calls share it.
`threadvar` keeps threads from sharing (and racing on) one backing.

```nim
import buffalo

var pool {.threadvar.}: PooledBuffer[byte]

proc handle(chunk: openArray[byte]) =
  if pool.cap == 0:
    pool = initPool(byte, 4096) # first call only
  withBorrow(pool, buf):
    buf.copyFrom(chunk)
    process(buf.toOpenArray())
```

### Zero-copy file scan

Map once, stride in fixed windows through a small pool. See
`examples/memfiles_scan.nim` for the full RSS-measured version.

```nim
import std/memfiles
import buffalo

var mf = memfiles.open(path, fmRead)
try:
  var pool = initPool(byte, 1024 * 1024)
  for slice in memChunks(mf, 1024 * 1024):
    withBorrow(pool, buf):
      buf.copyFromSlice(slice)
      process(buf.toOpenArray())
finally:
  mf.close()
```

Need a byte range instead? `buf.copyFromMemFile(mf, offset, len)`
copies exactly that window, bounds-checked on both ends.

## Retain vs Zero

Clearing defaults to `Retain`: reset `len`, keep the bytes. Fastest.

```nim
buf.clear()        # same as buf.clear(Retain)
buf.clear(Zero)    # zero the used prefix first, then reset
```

Use `Zero` for secrets or inter-tenant reuse, where leftover bytes must
not be observable. Pay it only where needed: the policy is a `typedesc`
resolved with `when`, so the unused branch never reaches codegen.

## Sizing and spikes

- `reserve(n)` / `ensureUnused(n)`: room for `n` total / `n` more.
  Static buffers check against `Cap`; pooled buffers grow.
- `setLen(n)`: shrink freely; growth zero-fills (safe on `{.noinit.}`).
- `pop()`: take the last element; raises on empty.
- `initPool(t, cap, maxCap = m)`: bound growth; exceeding `m` raises
  instead of allocating.
- `shrinkAfterSpike(steady)`: after a burst, drop back to
  `max(len, steady)` so long-running processes forget the peak.

`pool.cap` after warmup should never move in steady state. If it does,
the workload grew: that is the signal to `reserve` up front or raise
`maxCap` deliberately, not per iteration.

## Limits (best-effort checks)

The escape analysis is syntactic, not a borrow checker. It catches the
obvious leaks (return, store, address, closure) and allows the obvious
safe uses (scalars, elements, immediate call args, copies). It cannot
see through `foo(buf)` when `foo` stashes its argument elsewhere, and
copies you make (`var s = buf.toSeq()`) are owned values you manage
yourself. Keep borrows short and local; copy out at the boundary.
