## Core reusable buffer types.
##
## Two backings, both framework-agnostic (no dependency on any web / async
## framework, only stdlib). All hot-path operations are `{.inline.}` so the
## DSL layer can reach zero runtime cost: a borrow is a single `len = 0`
## store plus direct indexed access, with no closure, no dispatch, no heap
## traffic in steady state.
##
## * `StaticBuffer[T, Cap]` - stack-resident, never allocates. Best for
##   fixed-size scratch (parsers, encoders, line buffers). `T` should be a
##   plain value type (`byte`, `char`, numbers) for true zero cost; types
##   with `=destroy` still work but pay destructor cost at scope exit.
## * `PooledBuffer[T]` - heap backing allocated once via `initPool`, then
##   reused through `len` resets. Grows geometrically on overflow, then
##   stays flat. Best for variable-length work.
##
## Custom backings interoperate through structural convention, not
## inheritance: any type with `len: int`, `cap: int`, `clear()` and
## `add(T)` satisfies `BuffaloBacking` and works with `withBorrow`.

import std/typetraits

template buffalo* {.pragma.}
  ## Marker pragma: `var scratch {.buffalo.}: StaticBuffer[byte, 4096]`.
  ## Only meaningful inside `buffaloScope` (see `dsl.nim`), which strips it,
  ## adds `{.noinit.}` when the type is directly spelled
  ## `StaticBuffer[POD, Cap]` (otherwise keeps zero-init for safety),
  ## injects a `clear()` reset, and enforces no-escape.
  ## Outside `buffaloScope` the pragma is inert.

type
  StaticBuffer*[T; Cap: static int] = object
    ## Fixed-capacity reusable buffer. Declare with `{.noinit.}` (or via
    ## `{.buffalo.}` inside `buffaloScope`) to skip zero-initialisation.
    data*: array[Cap, T]
    len*: int

  PooledBuffer*[T] = object
    ## Growable reusable buffer. `data.len` is capacity, `len` is used.
    ## `maxCap` bounds future growth (`0` = unbounded); see `setMaxCap`.
    data*: seq[T]
    len*: int
    maxCap*: int

  BuffaloBacking*[T] = concept b, var bv
    ## Structural interface for framework-agnostic custom backings.
    b.len is int
    b.cap is int
    bv.clear()
    bv.add(T)

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

func cap*[T; Cap: static int](b: StaticBuffer[T, Cap]): int {.inline.} =
  ## Compile-time constant, folds to an immediate. Zero cost.
  Cap

func cap*[T](b: PooledBuffer[T]): int {.inline.} =
  b.data.len

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func initPool*[T](t: typedesc[T], cap: int, maxCap: int = 0): PooledBuffer[T] =
  ## Allocate backing once. Call outside the hot loop, then borrow inside.
  ## `t` is only for inference: `initPool(byte, 4096)`. `maxCap` optionally
  ## bounds future growth (`0` = unbounded); growth past it raises
  ## `RangeDefect` instead of allocating.
  result.data = newSeq[T](cap)
  result.len = 0
  result.maxCap = maxCap

# ---------------------------------------------------------------------------
# Clearing (policy via static `zero` flag so branches vanish at compile time)
# ---------------------------------------------------------------------------

proc clear*[T; Cap: static int](
    b: var StaticBuffer[T, Cap]; zero: static bool = false
) {.inline.} =
  when zero:
    when supportsCopyMem(T):
      if b.len > 0:
        zeroMem(addr b.data[0], b.len * sizeof(T))
    else:
      for i in 0 ..< b.len:
        b.data[i] = default(T)
  b.len = 0

proc clear*[T](b: var PooledBuffer[T]; zero: static bool = false) {.inline.} =
  when zero:
    when supportsCopyMem(T):
      if b.len > 0:
        zeroMem(addr b.data[0], b.len * sizeof(T))
    else:
      for i in 0 ..< b.len:
        b.data[i] = default(T)
  b.len = 0

# ---------------------------------------------------------------------------
# Growth (pooled only; amortised, no cost once at steady state)
# ---------------------------------------------------------------------------

proc ensureCap*[T](b: var PooledBuffer[T], need: int) {.inline.} =
  if b.data.len < need:
    if b.maxCap > 0 and need > b.maxCap:
      raise newException(RangeDefect, "PooledBuffer growth cap exceeded")
    var grown =
      if b.data.len <= 0:
        max(need, 8)
      else:
        max(need, b.data.len * 2)
    if b.maxCap > 0 and grown > b.maxCap:
      grown = b.maxCap
    b.data.setLen(grown)

# ---------------------------------------------------------------------------
# Length management (shrink is free; growth zero-fills, so it is safe
# on `{.noinit.}` scratch)
# ---------------------------------------------------------------------------

proc setLen*[T; Cap: static int](b: var StaticBuffer[T, Cap], n: int) {.inline.} =
  if n < 0 or n > Cap:
    raise newException(RangeDefect, "StaticBuffer setLen out of range")
  if n > b.len:
    when supportsCopyMem(T):
      zeroMem(addr b.data[b.len], (n - b.len) * sizeof(T))
    else:
      for i in b.len ..< n:
        b.data[i] = default(T)
  b.len = n

proc setLen*[T](b: var PooledBuffer[T], n: int) {.inline.} =
  if n < 0:
    raise newException(RangeDefect, "PooledBuffer setLen out of range")
  b.ensureCap(n) # honours maxCap, may raise
  if n > b.len:
    when supportsCopyMem(T):
      zeroMem(addr b.data[b.len], (n - b.len) * sizeof(T))
    else:
      for i in b.len ..< n:
        b.data[i] = default(T)
  b.len = n

proc pop*[T; Cap: static int](b: var StaticBuffer[T, Cap]): T {.inline.} =
  if b.len <= 0:
    raise newException(RangeDefect, "StaticBuffer pop from empty buffer")
  dec b.len
  result = move(b.data[b.len])

proc pop*[T](b: var PooledBuffer[T]): T {.inline.} =
  if b.len <= 0:
    raise newException(RangeDefect, "PooledBuffer pop from empty buffer")
  dec b.len
  result = move(b.data[b.len])

# ---------------------------------------------------------------------------
# Length guarantee without fill (hot-loop refill pattern)
# ---------------------------------------------------------------------------

proc ensureLen*[T; Cap: static int](b: var StaticBuffer[T, Cap], n: int
) {.inline.} =
  ## Ensure `len >= n`, growing `len` only (fixed storage cannot grow, so
  ## `n` must fit `Cap`). Unlike `setLen`, the newly exposed range is NOT
  ## zero-filled: the caller must overwrite `[oldLen, n)` before reading it
  ## (e.g. an explicit `zeroMem`, a full `copyFrom`, or per-element fill).
  ## Trusts the caller like `addUnchecked`; raises when `n` is out of range.
  if n < 0 or n > Cap:
    raise newException(RangeDefect, "StaticBuffer ensureLen out of range")
  if b.len < n:
    b.len = n

proc ensureLen*[T](b: var PooledBuffer[T], n: int) {.inline.} =
  ## Ensure `len >= n`, growing the backing geometrically when short
  ## (honours `maxCap`, may raise). Newly exposed elements are NOT
  ## zero-filled: overwrite before reading.
  if n < 0:
    raise newException(RangeDefect, "PooledBuffer ensureLen out of range")
  b.ensureCap(n)
  if b.len < n:
    b.len = n

# ---------------------------------------------------------------------------
# Capacity management (reserve ahead, release after spikes)
# ---------------------------------------------------------------------------

proc reserve*[T; Cap: static int](b: var StaticBuffer[T, Cap], n: int) {.inline.} =
  ## Fixed storage: a bounds check only, so generic code over both
  ## backings can reserve ahead. Raises when `n` exceeds `Cap`.
  if n < 0 or n > Cap:
    raise newException(RangeDefect, "StaticBuffer reserve out of range")

proc reserve*[T](b: var PooledBuffer[T], n: int) {.inline.} =
  ## Ensure room for `n` elements total. Never shrinks.
  if n < 0:
    raise newException(RangeDefect, "PooledBuffer reserve out of range")
  b.ensureCap(n)

proc ensureUnused*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], n: int
) {.inline.} =
  ## Check room for `n` more elements beyond `len`. Raises on overflow.
  if n < 0 or b.len + n > Cap:
    raise newException(RangeDefect, "StaticBuffer ensureUnused out of range")

proc ensureUnused*[T](b: var PooledBuffer[T], n: int) {.inline.} =
  ## Ensure room for `n` more elements beyond `len`.
  if n < 0:
    raise newException(RangeDefect, "PooledBuffer ensureUnused out of range")
  b.ensureCap(b.len + n)

proc shrinkToFit*[T; Cap: static int](b: var StaticBuffer[T, Cap]) {.inline.} =
  ## Fixed storage: no-op, present so generic code compiles over both
  ## backings.
  discard

proc shrinkToFit*[T](b: var PooledBuffer[T]) {.inline.} =
  ## Release excess backing after a spike. `len` is preserved.
  if b.data.len != b.len:
    b.data.setLen(b.len)

proc setMaxCap*[T](b: var PooledBuffer[T], m: int) {.inline.} =
  ## Cap future growth at `m` elements (`0` removes the cap). Shrinks the
  ## backing immediately when it exceeds `m`. Raises when `m` is below
  ## the used length.
  if m < 0:
    raise newException(RangeDefect, "PooledBuffer maxCap out of range")
  if m > 0 and m < b.len:
    raise newException(RangeDefect, "PooledBuffer maxCap below used length")
  b.maxCap = m
  if m > 0 and b.data.len > m:
    b.data.setLen(m)

proc shrinkAfterSpike*[T](b: var PooledBuffer[T], steady: int) {.inline.} =
  ## Drop the backing to `max(len, steady)` after a large spike, so a
  ## long-running process does not hold peak memory forever. Respects
  ## `maxCap` (raises when `steady` exceeds it).
  b.shrinkToFit()
  b.reserve(steady)

# ---------------------------------------------------------------------------
# Push / index (single predictable branch in steady state)
# ---------------------------------------------------------------------------

proc add*[T; Cap: static int](b: var StaticBuffer[T, Cap], v: T) {.inline.} =
  if b.len >= Cap:
    raise newException(RangeDefect, "StaticBuffer overflow")
  b.data[b.len] = v
  inc b.len

proc addUnchecked*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], v: T
) {.inline.} =
  ## No bounds check. Use only when the caller has proven `len < Cap`
  ## (e.g. fixed-size protocol writes). Truly zero cost: one store + bump.
  b.data[b.len] = v
  inc b.len

proc add*[T](b: var PooledBuffer[T], v: T) {.inline.} =
  if b.len >= b.data.len:
    b.ensureCap(b.len + 1)
  b.data[b.len] = v
  inc b.len

proc `[]`*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], i: int
): var T {.inline.} =
  b.data[i]

proc `[]`*[T; Cap: static int](
    b: StaticBuffer[T, Cap], i: int
): lent T {.inline.} =
  b.data[i]

proc `[]`*[T](b: var PooledBuffer[T], i: int): var T {.inline.} =
  b.data[i]

proc `[]`*[T](b: PooledBuffer[T], i: int): lent T {.inline.} =
  b.data[i]

proc `[]=`*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], i: int, v: T
) {.inline.} =
  b.data[i] = v

proc `[]=`*[T](b: var PooledBuffer[T], i: int, v: T) {.inline.} =
  b.data[i] = v
