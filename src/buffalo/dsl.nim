## Scoped borrow DSL with compile-time escape checks.
##
## Primary API (all zero-cost: each expands to a `clear()` store plus direct
## access, no closure, no heap, no dispatch):
##
## ```nim
## var pool = initPool(byte, 4096)
## for chunk in incoming:
##   withBorrow(pool, buf):
##     buf.add(chunk)
##     process(buf.toOpenArray())
## ```
##
## Pragma sugar for stack scratch (skips O(Cap) zero-init via `{.noinit.}`):
##
## ```nim
## proc handle() =
##   buffaloScope:
##     var scratch {.buffalo.}: StaticBuffer[byte, 4096]
##     scratch.add(1)
## ```
##
## Escape rules (enforced syntactically at expansion time): a borrowed name
## must not `return` out of the scope, be assigned to `result`, or be
## captured by a nested `proc` / `func` / `iterator` / `lambda` / `do`.
## To move data out, copy explicitly with `toSeq` / `toString`.
## The check is best-effort syntactic analysis, not a borrow checker; the
## trusted `addUnchecked` path additionally assumes correct capacity
## reasoning by the caller.

import std/macros
import ./types

# ---------------------------------------------------------------------------
# Escape analysis helpers (syntactic, compile time only)
# ---------------------------------------------------------------------------

proc hasIdent(n: NimNode, name: string): bool =
  if n.kind in {nnkIdent, nnkSym}:
    return $n == name
  for c in n:
    if hasIdent(c, name):
      return true
  false

proc isSanctionedCopyCall(n: NimNode, name: string): bool =
  ## `b.toSeq()` / `b.toString()` / `toSeq(b)` — the explicit copy-out hatch.
  ## Views (`toOpenArray`, `memView`, ...) are NOT sanctioned.
  if n.kind != nnkCall:
    return false
  if n.len < 1:
    return false
  let callee = n[0]
  if callee.kind in {nnkIdent, nnkSym}:
    if $callee in ["toSeq", "toString"]:
      for i in 1 ..< n.len:
        if hasIdent(n[i], name):
          return true
  elif callee.kind == nnkDotExpr and callee.len == 2:
    if callee[1].kind in {nnkIdent, nnkSym} and
        $callee[1] in ["toSeq", "toString"]:
      if hasIdent(callee[0], name):
        return true
  false

proc hasBareIdent(n: NimNode, name: string): bool =
  ## `name` appearing outside a sanctioned `toSeq` / `toString` copy.
  ## `return buf.toSeq()` is allowed; `return buf` and
  ## `return buf.toOpenArray()` are not.
  if n.kind == nnkCall and isSanctionedCopyCall(n, name):
    return false
  if n.kind in {nnkIdent, nnkSym}:
    return $n == name
  for c in n:
    if hasBareIdent(c, name):
      return true
  false

proc findBadReturn(n: NimNode, name: string): NimNode =
  ## A `return` containing the borrowed name anywhere below (without
  ## crossing a nested routine boundary, which is a capture, not a return).
  if n.kind == nnkReturnStmt and hasBareIdent(n, name):
    return n
  if n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkLambda, nnkMethodDef}:
    return nil
  for c in n:
    let r = findBadReturn(c, name)
    if r != nil:
      return r
  nil

proc findBadResultAsgn(n: NimNode, name: string): NimNode =
  if n.kind == nnkAsgn:
    if n.len == 2 and n[0].kind in {nnkIdent, nnkSym} and $n[0] == "result":
      if hasBareIdent(n[1], name):
        return n
  if n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkLambda, nnkMethodDef}:
    return nil
  for c in n:
    let r = findBadResultAsgn(c, name)
    if r != nil:
      return r
  nil

proc checkClosure(n: NimNode, name: string) =
  ## Nested routine bodies must not mention the borrowed name at all.
  if n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkLambda, nnkDo}:
    if hasIdent(n, name):
      error(
        "buffalo: '" & name &
          "' must not be captured by a nested routine; process it inside the scope",
        n,
      )
  for c in n:
    checkClosure(c, name)

proc checkNoEscape(body: NimNode, name: string) =
  let badRet = findBadReturn(body, name)
  if badRet != nil:
    error(
      "buffalo: '" & name &
        "' must not escape via return; copy out with toSeq / toString",
      badRet,
    )
  let badRes = findBadResultAsgn(body, name)
  if badRes != nil:
    error(
      "buffalo: '" & name &
        "' must not escape via result; copy out with toSeq / toString",
      badRes,
    )
  checkClosure(body, name)

# ---------------------------------------------------------------------------
# withBorrow(pool, buf, body)
# ---------------------------------------------------------------------------

macro withBorrow*(pool: var auto, bufName: untyped, body: untyped): untyped =
  ## Borrow `pool` for the duration of `body` under the alias `bufName`.
  ## Expands to `pool.clear()` + `template bufName = pool` + body:
  ## the alias is resolved at compile time, so use costs nothing beyond
  ## direct field access. `pool` must be a plain variable (ident or
  ## field/index path without calls) so the alias cannot duplicate
  ## side effects.
  if bufName.kind notin {nnkIdent, nnkSym}:
    error("buffalo: borrow name must be a plain identifier", bufName)
  let bname = $bufName

  proc hasCall(n: NimNode): bool =
    if n.kind in {nnkCall, nnkCommand}:
      return true
    for c in n:
      if hasCall(c):
        return true
    false

  if pool.kind notin {nnkIdent, nnkSym, nnkDotExpr, nnkBracketExpr} or
      hasCall(pool):
    error(
      "buffalo: pool must be a plain variable (ident / field / index, no calls)",
      pool,
    )

  checkNoEscape(body, bname)
  result = quote do:
    `pool`.clear()
    block:
      template `bufName`: auto = `pool`
      `body`

# ---------------------------------------------------------------------------
# buffaloScope(body) + {.buffalo.} pragma
# ---------------------------------------------------------------------------

proc pragmaHasBuffalo(pragma: NimNode): bool =
  for p in pragma:
    if p.kind in {nnkIdent, nnkSym} and $p == "buffalo":
      return true
    if p.kind == nnkExprColonExpr and p.len > 0:
      let head = p[0]
      if head.kind in {nnkIdent, nnkSym} and $head == "buffalo":
        return true
  false

proc staticPodNoinitOk(typNode: NimNode): bool =
  ## Conservative syntactic check: add `{.noinit.}` only for
  ## `StaticBuffer[POD, Cap]` spelled directly. Anything else (PooledBuffer,
  ## aliases, inferred types, non-POD elements) keeps zero-initialisation:
  ## safe by default, since `noinit` on a seq header or a string array is UB.
  if typNode.kind != nnkBracketExpr or typNode.len < 3:
    return false
  let head = typNode[0]
  if head.kind notin {nnkIdent, nnkSym} or $head != "StaticBuffer":
    return false
  let elem = typNode[1]
  if elem.kind notin {nnkIdent, nnkSym}:
    return false
  const podNames = [
    "byte", "char", "bool", "int", "int8", "int16", "int32", "int64",
    "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64",
  ]
  for p in podNames:
    if $elem == p:
      return true
  false

proc pragmaHasColonBuffalo(pragma: NimNode): NimNode =
  for p in pragma:
    if p.kind == nnkExprColonExpr and p.len > 0:
      let head = p[0]
      if head.kind in {nnkIdent, nnkSym} and $head == "buffalo":
        return p
  nil

macro buffaloScope*(body: untyped): untyped =
  ## Rewrite every `var x {.buffalo.}: T` in the top level of `body` to
  ## `var x {.noinit.}: T` (only when `T` is directly spelled
  ## `StaticBuffer[POD, Cap]`, otherwise plain zero-init for safety)
  ## + `x.clear()`, then enforce no-escape for each.
  ## Skipping zero-initialisation is what makes large stack scratch
  ## (`StaticBuffer[byte, 65536]`) free on entry: one `len = 0` store
  ## instead of an O(Cap) memset. Cross-call heap reuse still belongs to
  ## module-level pools + `withBorrow`; this scope owns stack lifetime.
  result = newStmtList()
  var buffaloNames: seq[string] = @[]
  var rest = newStmtList()

  for stmt in body:
    if stmt.kind == nnkLetSection:
      for defs in stmt:
        if defs.kind != nnkIdentDefs:
          continue
        for i in 0 ..< defs.len - 2:
          let nameNode = defs[i]
          if nameNode.kind == nnkPragmaExpr and pragmaHasBuffalo(nameNode[1]):
            error(
              "buffalo: {.buffalo.} requires var (mutable reuse), not let",
              defs,
            )
    if stmt.kind != nnkVarSection:
      rest.add(stmt.copyNimTree())
      continue

    for defs in stmt:
      if defs.kind != nnkIdentDefs or defs.len < 3:
        rest.add(nnkVarSection.newTree(defs.copyNimTree()))
        continue
      let nNames = defs.len - 2
      let typNode = defs[nNames]
      let valNode = defs[nNames + 1]
      var hasBuffaloIdx = -1
      for i in 0 ..< nNames:
        let nameNode = defs[i]
        if nameNode.kind == nnkPragmaExpr and pragmaHasBuffalo(nameNode[1]):
          hasBuffaloIdx = i
          break
      if hasBuffaloIdx < 0:
        rest.add(nnkVarSection.newTree(defs.copyNimTree()))
        continue
      if nNames != 1:
        error(
          "buffalo: one {.buffalo.} variable per declaration; split `var a, b` into separate lines",
          defs,
        )
      let nameNode = defs[0]
      let target = nameNode[0]
      let pragma = nameNode[1]
      let colonForm = pragmaHasColonBuffalo(pragma)
      if colonForm != nil:
        error(
          "buffalo: {.buffalo: pool.} is not supported; bind pools with withBorrow(pool, buf): ...",
          defs,
        )
      if target.kind notin {nnkIdent, nnkSym}:
        error(
          "buffalo: {.buffalo.} needs a plain identifier",
          defs,
        )
      let bname = $target
      buffaloNames.add(bname)

      var kept = nnkPragma.newTree()
      for p in pragma:
        if p.kind in {nnkIdent, nnkSym} and $p == "buffalo":
          continue
        kept.add(p.copyNimTree())
      var hasNoinit = false
      for p in kept:
        if p.kind in {nnkIdent, nnkSym}:
          let pn = $p
          if pn == "noinit" or pn == "noInit":
            hasNoinit = true
      # `noinit` only for directly-spelled StaticBuffer[POD]: skipping
      # zero-init on a seq header or non-POD array would be UB.
      if not hasNoinit and staticPodNoinitOk(typNode):
        kept.add(ident("noinit"))
      let targetCopy = target.copyNimTree()
      let newName =
        if kept.len > 0:
          nnkPragmaExpr.newTree(targetCopy, kept)
        else:
          targetCopy
      rest.add(
        nnkVarSection.newTree(
          nnkIdentDefs.newTree(
            newName, typNode.copyNimTree(), valNode.copyNimTree()
          )
        )
      )
      rest.add(
        nnkCall.newTree(
          nnkDotExpr.newTree(target.copyNimTree(), ident("clear"))
        )
      )

  # `rest` now holds everything in order (rewritten decls + clears + code).
  result = rest
  for bname in buffaloNames:
    checkNoEscape(result, bname)

# ---------------------------------------------------------------------------
# reuse(b, body)
# ---------------------------------------------------------------------------

template reuse*(b: var auto, body: untyped): untyped =
  ## Clear `b` and run `body`. Same lifetime, so no new escape rule beyond
  ## the enclosing scope. Handy for loop-carried stack scratch:
  ## `reuse(scratch): ...`.
  b.clear()
  body
