## Compile-time clear policies as distinct types.
##
## Passing a runtime flag would force a branch in the hot path. Passing a
## `typedesc` instead lets `when` resolve the choice during semantic
## analysis, so the discarded branch never reaches codegen.

import ./types

type
  Retain* = object
    ## Reset `len` only, keep backing bytes. Fastest. Default.

  Zero* = object
    ## Zero the used prefix, then reset `len`. For secrets / inter-tenant
    ## reuse. Cost is paid only where requested.

proc clear*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], _: typedesc[Retain]
) {.inline.} =
  b.clear()

proc clear*[T; Cap: static int](
    b: var StaticBuffer[T, Cap], _: typedesc[Zero]
) {.inline.} =
  b.clear(zero = true)

proc clear*[T](b: var PooledBuffer[T], _: typedesc[Retain]) {.inline.} =
  b.clear()

proc clear*[T](b: var PooledBuffer[T], _: typedesc[Zero]) {.inline.} =
  b.clear(zero = true)
