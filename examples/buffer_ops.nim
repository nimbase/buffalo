## Length and capacity management (the B ops).
##
## Run: `clue build examples/buffer_ops.nim --release --out:/tmp/ops`
##
## Shows: `setLen` (shrink free, grow zero-fills), `pop`, `reserve` /
## `ensureUnused`, `shrinkToFit`, `maxCap` bounding, and `shrinkAfterSpike`
## after a traffic spike. Prints the backing size at each step so the
## capacity behavior is visible.

import buffalo

proc show[T](name: string, b: PooledBuffer[T]) =
  echo name, ": len=", b.len, " cap=", b.cap,
    " maxCap=", b.maxCap

# setLen: shrink is free, growth zero-fills (safe on noinit scratch).
buffaloScope:
  var scratch {.buffalo.}: StaticBuffer[byte, 16]
  scratch.appendMany([1'u8, 2, 3, 4])
  scratch.setLen(2)
  echo "static setLen(2): len=", scratch.len
  scratch.setLen(4) # regrow: fresh slots read back as zero
  echo "static setLen(4): slot[2]=", scratch[2], " slot[3]=", scratch[3]
  scratch.clear()
  scratch.appendMany([7'u8, 8, 9])
  echo "static pop: ", scratch.pop(), " then ", scratch.pop(),
    " (len=", scratch.len, ")"

# reserve ahead, then release after a spike.
var pool = initPool(byte, 8)
pool.reserve(1024) # one allocation before the hot loop
echo "after reserve(1024): len=", pool.len, " cap=", pool.cap
withBorrow(pool, buf):
  buf.copyFrom("hello")
  echo "borrowed view: ", buf.toString(), " (cap still ", buf.cap, ")"
pool.shrinkToFit()
echo "after shrinkToFit: len=", pool.len, " cap=", pool.cap

# Bound growth: the pool absorbs bursts up to maxCap, then says no.
var bounded = initPool(byte, 4, maxCap = 16)
for i in 0 ..< 16:
  bounded.add(byte(i))
show("bounded full ", bounded)
try:
  bounded.add(16)
except RangeDefect:
  echo "bounded add(17th): RangeDefect, pool unchanged cap=", bounded.cap

# Spike handling: absorb 64 KB, then drop back to a 256 B working set.
var spike = initPool(byte, 256)
withBorrow(spike, buf):
  buf.setLen(65536)
  for i in 0 ..< buf.len:
    buf[i] = byte(i and 0xFF)
echo "spike absorbed: cap=", spike.cap
spike.clear()
spike.setLen(3)
spike.shrinkAfterSpike(256)
show("after shrinkAfterSpike(256)", spike)

# Char buffers take strings on both backings.
var text = initPool(char, 8)
text.copyFrom("hello")
text.appendMany(", world")
echo "pooled char: ", text.toString()
buffaloScope:
  var word {.buffalo.}: StaticBuffer[char, 8]
  word.copyFrom("nim")
  echo "static char: ", word.toString(), " pop=", word.pop()
