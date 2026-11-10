## buffalo - generic, framework-agnostic buffer reuse with zero runtime cost.
##
## The whole API is compile-time: `StaticBuffer` / `PooledBuffer` value
## types plus the `withBorrow` / `buffaloScope` / `reuse` DSL and the
## `{.buffalo.}` pragma. Borrows expand to a `len = 0` store and direct
## indexed access; views (`toOpenArray`, `memView`) expand to fat pointers.
## Nothing allocates in the hot path after the one-time `initPool`.
##
## ```nim
## import buffalo
##
## var pool = initPool(byte, 4096)      # once
## for chunk in incoming:
##   withBorrow(pool, buf):             # reuse, no alloc
##     buf.appendMany(chunk)
##     handle(buf.toOpenArray())
##
## proc parse() =
##   buffaloScope:                      # stack scratch, no zeroing
##     var scratch {.buffalo.}: StaticBuffer[byte, 1024]
##     scratch.copyFrom("hello")
## ```

import ./buffalo/types
import ./buffalo/policy
import ./buffalo/dsl
import ./buffalo/adapters

export types
export policy
export dsl
export adapters
