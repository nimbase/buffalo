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
    data*: seq[T]
    len*: int

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

func initPool*[T](t: typedesc[T], cap: int): PooledBuffer[T] =
  ## Allocate backing once. Call outside the hot loop, then borrow inside.
  ## `t` is only for inference: `initPool(byte, 4096)`.
  result.data = newSeq[T](cap)
  result.len = 0

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
    let grown =
      if b.data.len <= 0:
        max(need, 8)
      else:
        max(need, b.data.len * 2)
    b.data.setLen(grown)

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
