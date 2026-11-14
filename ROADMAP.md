# Roadmap

`buffalo` already covers the basics: reusable `StaticBuffer` and `PooledBuffer` types, a scoped `withBorrow` / `reuse` DSL, `{.buffalo.}` scratch inside `buffaloScope`, compile-time escape checks, and zero-copy adapters for common data (including `std/memfiles`).

This roadmap lists ideas for what could come next. It is a guide, not a promise. Items may shift based on real-world use.

## Near term (v0.2)

Focus: make the current API easier to trust and easier to use day to day.

- **Stronger escape checks**: today we catch `return`, `result =`, and closure capture. Extend the checks to reject other obvious escapes, like storing the borrowed handle in an outer variable or taking its address.
- **Clearer compile-time errors**: include the offending name and a short "what to do instead" hint (for example, copy out with `toSeq` / `toString`).
- **More buffer operations**: common helpers such as `setLen` (shrink/grow within capacity), `reserve`/`ensureUnused`, `pop`, and slicing helpers, all `{.inline.}` and allocation-free in steady state.
- **Pooled buffer ergonomics**: options to cap growth or shrink after a large spike, so long-running processes do not hold on to peak memory forever.
- **Better docs and examples**: a small guide covering "which buffer to pick", policy choices (`Retain` vs `Zero`), and patterns for parsing, encoding, and IO loops.
- **Tests and CI**: run `clue test` across debug/release and ARC/ORC, and add a few compile-fail tests for the escape checks.

## Mid term (v0.3+)

Focus: broader integrations and reusable patterns.

- **Cross-call reuse helpers**: safe, explicit patterns for promoting scratch to module-level or `threadvar` pools (building on the `{.buffalo.}` idea) so call sites stay simple without hidden globals.
- **More adapters**: convenient views/copies for streams, `ptr UncheckedArray` ranges, and other stdlib IO types, while keeping the core framework agnostic.
- **Writable memory-mapped workflows**: helpers for reusing buffers alongside writable `MemFile` mappings, with clear ownership rules.
- **String/byte builder conveniences**: small, zero-surprise helpers for building text or binary payloads on top of a reusable buffer.
- **Benchmarks**: reproducible micro-benchmarks comparing reuse vs fresh allocations, so the "zero cost" claim stays honest and measurable.

## Later / ideas

Focus: explore, only if they stay simple and true to zero-cost.

- **Concurrency patterns**: guidance or helpers for per-thread pools and producer/consumer handoff without accidental sharing.
- **Custom allocator hooks**: optional integration points for environments that bring their own allocator, without changing the default path.
- **Richer compile-time diagnostics**: opt-in checks that explain why a borrow was accepted or rejected.
- **Ecosystem examples**: small, framework-agnostic snippets showing `buffalo` in parsers, networking, and file processing.

## Non-goals (for now)

- Becoming a full collections or serialization library.
- Hiding costs behind implicit allocations or runtime dispatch.
- Depending on any specific web, async, or application framework.

If you have a use case that does not fit yet, open an issue with a short example. Real workloads are the best way to decide what comes next.
