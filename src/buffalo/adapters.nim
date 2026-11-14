## Zero-copy views and bulk adapters for stdlib types + `std/memfiles`.
##
## Views (`toOpenArray`, `memView`, `sliceView`) are `template`s, not procs:
## Nim 2.x cannot return `openArray`, so a proc would be forced to copy.
## A template expands to the builtin `toOpenArray(data, 0, len-1)` at the
## call site, which the compiler turns into a fat pointer (ptr + len) in a
## register pair. No allocation, no copy. Verified: empty buffers expand to
## `toOpenArray(data, 0, -1)`, which yields a zero-length view.
##
## Copying adapters (`toSeq`, `toString`, `copyFrom`, `appendMany`) do
## allocate / copy by design: they are the explicit escape hatch for moving
## data out of a borrow scope. Bulk paths use `copyMem` when
## `supportsCopyMem(T)` (selected with `when`, so the branch is gone at
## codegen) and element-wise `=copy` otherwise, keeping custom types safe.

import std/typetraits
import std/memfiles
import ./types

# ---------------------------------------------------------------------------
# Views (zero-copy, template so no openArray return is needed)
# ---------------------------------------------------------------------------

template toOpenArray*[T; Cap: static int](
    b: StaticBuffer[T, Cap]
): untyped =
  ## Borrow the used prefix as `openArray[T]`. Use directly as a call
  ## argument: `process(buf.toOpenArray())`. Must not escape the scope.
  toOpenArray(b.data, 0, b.len - 1)

template toOpenArray*[T](b: PooledBuffer[T]): untyped =
  toOpenArray(b.data, 0, b.len - 1)

template memView*(mf: MemFile): untyped =
  ## Zero-copy `openArray[byte]` over a mapped file.
  toOpenArray(cast[ptr UncheckedArray[byte]](mf.mem), 0, mf.size - 1)

template sliceView*(ms: MemSlice): untyped =
  ## Zero-copy `openArray[byte]` over a `MemSlice` (e.g. from `memSlices`).
  toOpenArray(cast[ptr UncheckedArray[byte]](ms.data), 0, ms.size - 1)

template ptrView*[T](p: ptr UncheckedArray[T], n: int): untyped =
  ## Zero-copy view over `n` elements at raw pointer `p`.
  toOpenArray(p, 0, n - 1)

iterator memChunks*(mf: MemFile, chunkSize: int): MemSlice {.inline.} =
  ## Fixed-size striding over a mapping for chunked reuse: pair with
  ## `copyFromSlice` (copy into a small pool) or `sliceView` (zero-copy).
  ## The last chunk may be shorter; an empty file yields nothing.
  ## Complements the delimiter-based `memSlices` for binary data.
  assert chunkSize > 0, "memChunks chunkSize must be positive"
  var off = 0
  while off < mf.size:
    let n = min(chunkSize, mf.size - off)
    yield MemSlice(data: cast[pointer](cast[int](mf.mem) +% off), size: n)
    off += n

# ---------------------------------------------------------------------------
# Copy out (allocating escape hatch)
# ---------------------------------------------------------------------------

proc toSeq*[T; Cap: static int](b: StaticBuffer[T, Cap]): seq[T] {.inline.} =
  result = newSeq[T](b.len)
  if b.len <= 0:
    return
  when supportsCopyMem(T):
    copyMem(addr result[0], unsafeAddr b.data[0], b.len * sizeof(T))
  else:
    for i in 0 ..< b.len:
      result[i] = b.data[i]

proc toSeq*[T](b: PooledBuffer[T]): seq[T] {.inline.} =
  result = newSeq[T](b.len)
  if b.len <= 0:
    return
  when supportsCopyMem(T):
    copyMem(addr result[0], unsafeAddr b.data[0], b.len * sizeof(T))
  else:
    for i in 0 ..< b.len:
      result[i] = b.data[i]

proc toString*[Cap: static int](b: StaticBuffer[byte, Cap]): string {.inline.} =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b.data[0], b.len)

proc toString*[Cap: static int](b: StaticBuffer[char, Cap]): string {.inline.} =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b.data[0], b.len)

proc toString*(b: PooledBuffer[byte]): string {.inline.} =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b.data[0], b.len)

proc toString*(b: PooledBuffer[char]): string {.inline.} =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b.data[0], b.len)

# ---------------------------------------------------------------------------
# Bulk fill: replace (`copyFrom`) vs append (`appendMany`)
# ---------------------------------------------------------------------------

proc copyFrom*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], src: openArray[T]
) {.inline.} =
  ## Replace contents with `src`. Raises on overflow (fixed capacity).
  if src.len > Cap:
    raise newException(RangeDefect, "StaticBuffer copyFrom overflow")
  when supportsCopyMem(T):
    if src.len > 0:
      copyMem(addr b.data[0], unsafeAddr src[0], src.len * sizeof(T))
  else:
    for i in 0 ..< src.len:
      b.data[i] = src[i]
  b.len = src.len

proc copyFrom*[T](b: var PooledBuffer[T], src: openArray[T]) {.inline.} =
  ## Replace contents with `src`, growing the backing once if needed.
  b.ensureCap(src.len)
  when supportsCopyMem(T):
    if src.len > 0:
      copyMem(addr b.data[0], unsafeAddr src[0], src.len * sizeof(T))
  else:
    for i in 0 ..< src.len:
      b.data[i] = src[i]
  b.len = src.len

proc appendMany*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], src: openArray[T]
) {.inline.} =
  if b.len + src.len > Cap:
    raise newException(RangeDefect, "StaticBuffer append overflow")
  when supportsCopyMem(T):
    if src.len > 0:
      copyMem(addr b.data[b.len], unsafeAddr src[0], src.len * sizeof(T))
  else:
    for i in 0 ..< src.len:
      b.data[b.len + i] = src[i]
  b.len += src.len

proc appendMany*[T](b: var PooledBuffer[T], src: openArray[T]) {.inline.} =
  b.ensureCap(b.len + src.len)
  when supportsCopyMem(T):
    if src.len > 0:
      copyMem(addr b.data[b.len], unsafeAddr src[0], src.len * sizeof(T))
  else:
    for i in 0 ..< src.len:
      b.data[b.len + i] = src[i]
  b.len += src.len

# `string` is `openArray[char]`, not `openArray[byte]`: explicit overloads
# so byte buffers accept string input without a caller-side cast loop.
# `PooledBuffer[char]` needs none: the generic `openArray[T]` overloads
# accept strings directly (covered by tests).

proc copyFrom*[Cap: static int](
    b: var StaticBuffer[byte, Cap], src: string
) {.inline.} =
  if src.len > Cap:
    raise newException(RangeDefect, "StaticBuffer copyFrom overflow")
  if src.len > 0:
    copyMem(addr b.data[0], unsafeAddr src[0], src.len)
  b.len = src.len

proc copyFrom*[Cap: static int](
    b: var StaticBuffer[char, Cap], src: string
) {.inline.} =
  if src.len > Cap:
    raise newException(RangeDefect, "StaticBuffer copyFrom overflow")
  for i in 0 ..< src.len:
    b.data[i] = src[i]
  b.len = src.len

proc appendMany*[Cap: static int](
    b: var StaticBuffer[char, Cap], src: string
) {.inline.} =
  if b.len + src.len > Cap:
    raise newException(RangeDefect, "StaticBuffer append overflow")
  for i in 0 ..< src.len:
    b.data[b.len + i] = src[i]
  b.len += src.len

proc copyFrom*(b: var PooledBuffer[byte], src: string) {.inline.} =
  b.ensureCap(src.len)
  if src.len > 0:
    copyMem(addr b.data[0], unsafeAddr src[0], src.len)
  b.len = src.len

proc appendMany*[Cap: static int](
    b: var StaticBuffer[byte, Cap], src: string
) {.inline.} =
  if b.len + src.len > Cap:
    raise newException(RangeDefect, "StaticBuffer append overflow")
  if src.len > 0:
    copyMem(addr b.data[b.len], unsafeAddr src[0], src.len)
  b.len += src.len

proc appendMany*(b: var PooledBuffer[byte], src: string) {.inline.} =
  b.ensureCap(b.len + src.len)
  if src.len > 0:
    copyMem(addr b.data[b.len], unsafeAddr src[0], src.len)
  b.len += src.len

# ---------------------------------------------------------------------------
# Bounds-checked blit (replaces per-byte copy loops)
# ---------------------------------------------------------------------------

proc blit*[T](dst: var openArray[T], src: openArray[T]) {.inline.} =
  ## Copy `src` into `dst[0 ..< src.len]`, replacing `for i, v in src:
  ## dst[i] = v` loops. Raises `RangeDefect` when `src` does not fit.
  ## Bulk path uses `copyMem` for memcpy-able types, element-wise `=copy`
  ## otherwise (same policy as `copyFrom` / `appendMany`).
  if src.len > dst.len:
    raise newException(RangeDefect, "buffalo blit: src exceeds dst")
  when supportsCopyMem(T):
    if src.len > 0:
      copyMem(addr dst[0], unsafeAddr src[0], src.len * sizeof(T))
  else:
    for i in 0 ..< src.len:
      dst[i] = src[i]

# ---------------------------------------------------------------------------
# memfiles adapters
# ---------------------------------------------------------------------------

proc copyFromMemFile*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], mf: MemFile
) {.inline.} =
  ## Bulk-copy a mapped file into a fixed buffer. `byte`/`char` only;
  ## other element types would need width conversion, reject at compile time.
  static:
    assert T is byte or T is char
  if mf.size > Cap:
    raise newException(RangeDefect, "StaticBuffer copyFromMemFile overflow")
  if mf.size > 0:
    copyMem(addr b.data[0], mf.mem, mf.size)
  b.len = mf.size

proc copyFromMemFile*[T](b: var PooledBuffer[T], mf: MemFile) {.inline.} =
  static:
    assert T is byte or T is char
  b.ensureCap(mf.size)
  if mf.size > 0:
    copyMem(addr b.data[0], mf.mem, mf.size)
  b.len = mf.size

proc copyFromMemFile*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], mf: MemFile, offset, len: int
) {.inline.} =
  ## Bulk-copy `len` bytes at `offset` into a fixed buffer. Bounds-checked
  ## on both the mapping and the capacity; the chunked-reuse primitive
  ## behind `memChunks` loops (or use `copyFromSlice` per chunk).
  static:
    assert T is byte or T is char
  if offset < 0 or len < 0 or offset > mf.size or len > mf.size - offset:
    raise newException(RangeDefect, "copyFromMemFile range out of bounds")
  if len > Cap:
    raise newException(RangeDefect, "StaticBuffer copyFromMemFile overflow")
  if len > 0:
    copyMem(addr b.data[0], cast[pointer](cast[int](mf.mem) +% offset), len)
  b.len = len

proc copyFromMemFile*[T](
    b: var PooledBuffer[T], mf: MemFile, offset, len: int
) {.inline.} =
  static:
    assert T is byte or T is char
  if offset < 0 or len < 0 or offset > mf.size or len > mf.size - offset:
    raise newException(RangeDefect, "copyFromMemFile range out of bounds")
  b.ensureCap(len)
  if len > 0:
    copyMem(addr b.data[0], cast[pointer](cast[int](mf.mem) +% offset), len)
  b.len = len

proc copyFromSlice*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], ms: MemSlice
) {.inline.} =
  static:
    assert T is byte or T is char
  if ms.size > Cap:
    raise newException(RangeDefect, "StaticBuffer copyFromSlice overflow")
  if ms.size > 0:
    copyMem(addr b.data[0], ms.data, ms.size)
  b.len = ms.size

proc copyFromSlice*[T](b: var PooledBuffer[T], ms: MemSlice) {.inline.} =
  static:
    assert T is byte or T is char
  b.ensureCap(ms.size)
  if ms.size > 0:
    copyMem(addr b.data[0], ms.data, ms.size)
  b.len = ms.size

# ---------------------------------------------------------------------------
# memfiles write-back (buffer -> mapping, never grows either side)
# ---------------------------------------------------------------------------
# Ownership: the mapping owns its memory; the buffer is scratch. These
# procs only `copyMem` the used prefix (`b.len` bytes, or `len` bytes of
# it) into the mapping. They never touch buffer capacity, buffer `len`,
# or mapping `size`. The caller flushes (`mf.flush()`) and closes.
# Open the mapping with write access (e.g. `fmReadWrite`); a read-only
# mapping will fault on write. Steady-state cost is one bounds check
# plus the copy itself: repeated calls do not allocate or grow.

proc copyToSlice*[T; Cap: static int](
    b: StaticBuffer[T, Cap], ms: MemSlice
) {.inline.} =
  ## Write the used prefix into a slice (e.g. a `memChunks` window).
  ## Raises when `b.len` exceeds `ms.size`; buffer `len` is preserved.
  static:
    assert T is byte or T is char
  if b.len > ms.size:
    raise newException(RangeDefect, "copyToSlice overflow: buffer exceeds slice")
  if b.len > 0:
    copyMem(ms.data, unsafeAddr b.data[0], b.len)

proc copyToSlice*[T](b: PooledBuffer[T], ms: MemSlice) {.inline.} =
  static:
    assert T is byte or T is char
  if b.len > ms.size:
    raise newException(RangeDefect, "copyToSlice overflow: buffer exceeds slice")
  if b.len > 0:
    copyMem(ms.data, unsafeAddr b.data[0], b.len)

proc copyToMemFile*[T; Cap: static int](
    b: StaticBuffer[T, Cap], mf: MemFile
) {.inline.} =
  ## Write the used prefix into the whole mapping. Raises when `b.len`
  ## exceeds `mf.size`; buffer `len` and mapping `size` are preserved.
  static:
    assert T is byte or T is char
  if b.len > mf.size:
    raise newException(RangeDefect, "copyToMemFile overflow: buffer exceeds mapping")
  if b.len > 0:
    copyMem(mf.mem, unsafeAddr b.data[0], b.len)

proc copyToMemFile*[T](b: PooledBuffer[T], mf: MemFile) {.inline.} =
  static:
    assert T is byte or T is char
  if b.len > mf.size:
    raise newException(RangeDefect, "copyToMemFile overflow: buffer exceeds mapping")
  if b.len > 0:
    copyMem(mf.mem, unsafeAddr b.data[0], b.len)

proc copyToMemFile*[T; Cap: static int](
    b: StaticBuffer[T, Cap], mf: MemFile, offset, len: int
) {.inline.} =
  ## Write `len` bytes of the buffer prefix at `offset` in the mapping.
  ## Bounds-checked on both sides (`len <= b.len`, `offset + len <= mf.size`);
  ## overflow-safe comparison. Neither side grows.
  static:
    assert T is byte or T is char
  if offset < 0 or len < 0 or offset > mf.size or len > mf.size - offset:
    raise newException(RangeDefect, "copyToMemFile range out of bounds")
  if len > b.len:
    raise newException(RangeDefect, "copyToMemFile range exceeds buffer")
  if len > 0:
    copyMem(cast[pointer](cast[int](mf.mem) +% offset), unsafeAddr b.data[0], len)

proc copyToMemFile*[T](
    b: PooledBuffer[T], mf: MemFile, offset, len: int
) {.inline.} =
  static:
    assert T is byte or T is char
  if offset < 0 or len < 0 or offset > mf.size or len > mf.size - offset:
    raise newException(RangeDefect, "copyToMemFile range out of bounds")
  if len > b.len:
    raise newException(RangeDefect, "copyToMemFile range exceeds buffer")
  if len > 0:
    copyMem(cast[pointer](cast[int](mf.mem) +% offset), unsafeAddr b.data[0], len)
