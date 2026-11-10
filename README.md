<p align="center">
  Reuse buffers instead of allocating new ones, with a compile-time DSL<br>
  and zero runtime cost. Generic and framework agnostic.
</p>

<p align="center">
  <code>nimble install buffalo</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/buffalo/">API reference</a><br>
  <img src="https://github.com/nimbase/buffalo/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/buffalo/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features
- **Reuse memory in hot loops**: borrow a buffer, write into it, and hand it back when the scope ends. No fresh allocation every time.
- **Zero runtime overhead**: the DSL is made of macros, templates, and `{.inline.}` procs. A borrow becomes a simple `len = 0` reset and direct indexed access.
- **Two buffer styles**: `StaticBuffer` lives on the stack with a fixed capacity. `PooledBuffer` keeps a growable backing store that grows once, then stays flat.
- **Scoped borrow API**: `withBorrow(pool, buf): ...` gives you a short-lived handle. `reuse(buf): ...` clears an existing buffer for another pass.
- **Pragma sugar**: mark a local variable with `{.buffalo.}` inside `buffaloScope` to get stack scratch that is cleared for you, without paying for a full zero-fill on POD static buffers.
- **Safety checks at compile time**: the borrowed name cannot be returned, assigned to `result`, or captured by a nested routine. If you need the data outside the scope, copy it out explicitly.
- **Works with common data**: zero-copy views and bulk helpers for `seq`, `string`, arrays, raw pointers, and `std/memfiles`.

## Examples
### Reuse a pooled buffer in a loop
Create the pool once, outside the loop. Inside the loop, `withBorrow` resets it and lets you fill it again without allocating a new backing store.

```nim
import buffalo

proc handle(data: openArray[byte]) =
  # do something with the borrowed bytes
  discard data.len

var pool = initPool(byte, 4096) # allocate once

for chunk in ["alpha", "beta", "gamma"]:
  withBorrow(pool, buf):
    buf.copyFrom(chunk)          # replace contents, reusing the same memory
    handle(buf.toOpenArray())    # pass a zero-copy view
# pool can be reused again later
```

### Stack scratch with the `{.buffalo.}` pragma
`buffaloScope` rewrites marked locals for reuse. For a POD `StaticBuffer`, it skips the initial zero-fill and injects a `clear()` instead.

```nim
import buffalo

proc buildMessage(): string =
  buffaloScope:
    var scratch {.buffalo.}: StaticBuffer[byte, 256]
    scratch.copyFrom("hello")
    scratch.appendMany(", world")
    result = scratch.toString()  # explicit copy out of the scope
```

### Reuse the same buffer for several passes
`reuse` is a small helper: it clears the buffer, then runs your block. Handy when you keep one scratch buffer around.

```nim
import buffalo

var scratch: StaticBuffer[byte, 128]
scratch.len = 0

for word in ["one", "two", "three"]:
  reuse(scratch):
    scratch.copyFrom(word)
    # work with scratch.toOpenArray() here
```

### Read a memory-mapped file without copying
`memView` gives you an `openArray[byte]` over the mapped file, so you can scan it directly. If you want to keep the bytes, copy them into a reusable buffer.

```nim
import std/memfiles
import buffalo

var mf = memfiles.open("data.bin", fmRead)
try:
  let view = memView(mf)         # zero-copy view over the file
  # process view...

  var buf = initPool(byte, mf.size)
  buf.copyFromMemFile(mf)        # explicit copy into reusable storage
finally:
  mf.close()
```

### Moving data out of a borrow
A borrowed buffer must stay inside its scope. To keep the result, make a copy with `toSeq` or `toString`.

```nim
import buffalo

proc collect(): seq[byte] =
  var pool = initPool(byte, 64)
  withBorrow(pool, buf):
    buf.appendMany([1'u8, 2, 3])
    result = buf.toSeq()         # copies the bytes, so they can leave safely
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/buffalo/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/buffalo/fork)

### 🎩 License
MIT license | Nim Community.