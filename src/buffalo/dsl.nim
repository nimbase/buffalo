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
## must not `return` out of the scope, be assigned to `result`, be stored in
## another variable (`outer = buf`, `var x = buf`), have its address taken
## (`addr buf[0]`), be bound to a view variable, or be captured by a nested
## `proc` / `func` / `iterator` / `lambda` / `do`.
## Safe scalar uses are allowed: `buf.len`, `buf.cap`, `buf[i]` value copies,
## `foo(buf.toOpenArray())` as an immediate call argument, and explicit
## copy-out with `toSeq` / `toString`.
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
  ## Kept for backwards-compatible messages; new checks use
  ## `isEscapingExpr` which additionally allows safe scalars.
  if n.kind == nnkCall and isSanctionedCopyCall(n, name):
    return false
  if n.kind in {nnkIdent, nnkSym}:
    return $n == name
  for c in n:
    if hasBareIdent(c, name):
      return true
  false

proc isSafeFieldRead(n: NimNode, name: string): bool =
  ## `buf.len` / `buf.cap` are scalar copies, never an escape.
  if n.kind == nnkDotExpr and n.len == 2:
    let base = n[0]
    let field = n[1]
    if base.kind in {nnkIdent, nnkSym} and $base == name:
      if field.kind in {nnkIdent, nnkSym} and $field in ["len", "cap"]:
        return true
  false

proc isAddrNode(n: NimNode): tuple[isAddr: bool, target: NimNode] =
  ## `addr x`, `unsafeAddr x` appear as `nnkAddr` or as `Call`/`Command`
  ## with head `addr`/`unsafeAddr` (parens vs no parens in untyped AST).
  if n.kind in {nnkAddr, nnkHiddenAddr} and n.len >= 1:
    return (true, n[0])
  if n.kind in {nnkCall, nnkCommand} and n.len >= 2:
    let head = n[0]
    if head.kind in {nnkIdent, nnkSym} and $head in ["addr", "unsafeAddr"]:
      return (true, n[1])
  (false, nil)

proc isViewCtorCall(n: NimNode, name: string): bool =
  ## Functional view constructors rooted at the borrow, e.g.
  ## `toOpenArray(buf)`, `ptrView(...)` with a borrow inside.
  ## Caller must have excluded sanctioned copies already.
  if n.kind notin {nnkCall, nnkCommand} or n.len < 1:
    return false
  let callee = n[0]
  if callee.kind in {nnkIdent, nnkSym}:
    if $callee in ["toOpenArray", "sliceView", "ptrView", "memView",
        "toOpenArrayBA"]:
      for i in 1 ..< n.len:
        if hasIdent(n[i], name):
          return true
  false

proc isEscapingExpr(n: NimNode, name: string): bool =
  ## Does `n` denote the borrow itself or a view over its backing?
  ## Safe: `buf.len`/`cap`, `buf[i]` element values, sanctioned copies,
  ## generic computed calls like `sum(buf.toOpenArray())`.
  ## Escaping: `buf`, `buf.data`, `buf.toOpenArray()`, view ctors, `addr`.
  if n == nil:
    return false
  if isSanctionedCopyCall(n, name):
    return false
  if n.kind in {nnkIdent, nnkSym}:
    return $n == name
  if isSafeFieldRead(n, name):
    return false
  if n.kind == nnkBracketExpr and n.len >= 1:
    # Element value read (`buf[i]`, `buf.data[i]`) is a copy, not an escape.
    # Address-taking is handled separately via `isAddrNode`.
    return false
  let (isAddr, target) = isAddrNode(n)
  if isAddr:
    return hasIdent(target, name)
  if n.kind == nnkDotExpr and n.len == 2:
    # `.len` / `.cap` are scalar copies even on derived views
    # (`buf.toOpenArray().len`), never an escape.
    let field = n[1]
    if field.kind in {nnkIdent, nnkSym} and $field in ["len", "cap"]:
      return false
    # `buf.data` (or any other non-len/cap field) denotes backing memory.
    if n[0].kind in {nnkIdent, nnkSym} and $n[0] == name:
      return true
    # `(expr).field` where base escapes (e.g. view chains) propagates.
    if isEscapingExpr(n[0], name):
      return true
    return false
  if n.kind in {nnkCall, nnkCommand} and n.len >= 1:
    let callee = n[0]
    if callee.kind == nnkDotExpr and callee.len == 2:
      # Method on the borrow: `buf.toOpenArray()`, `buf.add(..)`.
      # Sanctioned copies already excluded above.
      if callee[0].kind in {nnkIdent, nnkSym} and $callee[0] == name:
        return true
      if isEscapingExpr(callee[0], name):
        return true
      # `foo(buf.view)` as immediate arg: result is computed, allow.
      return false
    if isViewCtorCall(n, name):
      return true
    # Generic call: `sum(buf.view)` returns a computed value, allow.
    return false
  if n.kind == nnkCast and n.len >= 1:
    for c in n:
      if isEscapingExpr(c, name):
        return true
    return false
  if n.kind in {nnkInfix, nnkPrefix}:
    for c in n:
      if c.kind in {nnkIdent, nnkSym}:
        continue
      if isEscapingExpr(c, name):
        return true
    return false
  # Transparent containers (`StmtList`, `Par`, `IfExpr`, ...): propagate.
  # Generic fallback would over-flag call args, so only propagate for
  # non-call nodes here; calls handled above.
  if n.kind notin {nnkCall, nnkCommand}:
    for c in n:
      if isEscapingExpr(c, name):
        return true
    return false
  false

proc isBorrowTarget(n: NimNode, name: string): bool =
  ## LHS denotes the borrow backing itself (mutation, allowed):
  ## `buf`, `buf[i]`, `buf.len`, `buf.data`, `buf.data[i]`.
  if n.kind in {nnkIdent, nnkSym}:
    return $n == name
  if n.kind == nnkDotExpr and n.len == 2:
    return isBorrowTarget(n[0], name)
  if n.kind == nnkBracketExpr and n.len >= 1:
    return isBorrowTarget(n[0], name)
  false

proc denotesBorrowMemory(n: NimNode, name: string): bool =
  ## For `addr`: does the pointee live in the borrow backing?
  ## Conservative on the base, lenient on indices (`outer[buf.len]` is fine).
  if n == nil:
    return false
  if n.kind in {nnkIdent, nnkSym}:
    return $n == name
  if n.kind == nnkDotExpr and n.len == 2:
    return denotesBorrowMemory(n[0], name)
  if n.kind == nnkBracketExpr and n.len >= 1:
    # Base rooted at borrow (or a view over it); indices ignored.
    return hasIdent(n[0], name)
  if isSanctionedCopyCall(n, name):
    return false
  if n.kind in {nnkCall, nnkCommand, nnkCast}:
    return hasIdent(n, name)
  for c in n:
    if denotesBorrowMemory(c, name):
      return true
  false

proc findBadReturn(n: NimNode, name: string): NimNode =
  ## A `return` of the borrow / view / address (scalar copies and
  ## sanctioned `toSeq`/`toString` are allowed).
  if n.kind == nnkReturnStmt:
    for c in n:
      if isEscapingExpr(c, name):
        return n
    return nil
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
      if isEscapingExpr(n[1], name):
        return n
  if n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkLambda, nnkMethodDef}:
    return nil
  for c in n:
    let r = findBadResultAsgn(c, name)
    if r != nil:
      return r
  nil

proc findBadVarLet(n: NimNode, name: string): NimNode =
  ## `var x = buf` / `let x = buf.view` binds the borrow to a new name.
  ## `var n = buf.len`, `var e = buf[0]`, `var s = buf.toSeq()` are fine.
  if n.kind in {nnkVarSection, nnkLetSection}:
    for defs in n:
      if defs.kind != nnkIdentDefs or defs.len < 3:
        continue
      let valNode = defs[defs.len - 1]
      if valNode.kind == nnkEmpty:
        continue
      if isEscapingExpr(valNode, name):
        return defs
  if n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkLambda, nnkMethodDef}:
    return nil
  for c in n:
    let r = findBadVarLet(c, name)
    if r != nil:
      return r
  nil

proc findBadAsgn(n: NimNode, name: string): NimNode =
  ## `outer = buf` / `outer = buf.view` stores the borrow outside.
  ## Mutations (`buf[i] = x`, `buf.len = n`) and scalar/element copies
  ## (`outer = buf.len`, `outer = buf[0]`) are allowed.
  if n.kind == nnkAsgn and n.len == 2:
    let lhs = n[0]
    let rhs = n[1]
    if lhs.kind in {nnkIdent, nnkSym} and $lhs == "result":
      discard # handled by findBadResultAsgn
    elif not isBorrowTarget(lhs, name):
      if isEscapingExpr(rhs, name):
        return n
  if n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkLambda, nnkMethodDef}:
    return nil
  for c in n:
    let r = findBadAsgn(c, name)
    if r != nil:
      return r
  nil

proc findBadAddr(n: NimNode, name: string): NimNode =
  ## `addr buf...` / `unsafeAddr buf...` takes a pointer into the backing.
  ## `addr outer[buf.len]` (borrow only in index) is allowed.
  let (isAddr, target) = isAddrNode(n)
  if isAddr:
    if denotesBorrowMemory(target, name):
      return n
  if n.kind in {nnkProcDef, nnkFuncDef, nnkIteratorDef, nnkLambda, nnkMethodDef}:
    return nil
  for c in n:
    let r = findBadAddr(c, name)
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
  let badAddr = findBadAddr(body, name)
  if badAddr != nil:
    error(
      "buffalo: '" & name &
        "' address must not escape (addr / unsafeAddr); process the buffer inside the scope",
      badAddr,
    )
  let badVar = findBadVarLet(body, name)
  if badVar != nil:
    error(
      "buffalo: '" & name &
        "' must not be bound to another variable; use it directly inside the scope or copy out with toSeq / toString",
      badVar,
    )
  let badAsgn = findBadAsgn(body, name)
  if badAsgn != nil:
    error(
      "buffalo: '" & name &
        "' must not be stored in another variable; use it directly inside the scope or copy out with toSeq / toString",
      badAsgn,
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
  ## Rewrite every `var x {.buffalo.}: T` at any statement nesting depth
  ## (top level, `block:`, `if:`/`when:` branches, loops, `try:`) to
  ## `var x {.noinit.}: T` (only when `T` is directly spelled
  ## `StaticBuffer[POD, Cap]`, otherwise plain zero-init for safety)
  ## + `x.clear()`, then enforce no-escape for each.
  ## Skipping zero-initialisation is what makes large stack scratch
  ## (`StaticBuffer[byte, 65536]`) free on entry: one `len = 0` store
  ## instead of an O(Cap) memset. Cross-call heap reuse still belongs to
  ## module-level pools + `withBorrow`; this scope owns stack lifetime.
  ## Nested routine bodies (`proc`/`func`/`iterator`/`lambda`/`do`/...) are
  ## separate scopes: a `{.buffalo.}` inside one is an error suggesting an
  ## inner `buffaloScope`.
  proc isRoutineDef(n: NimNode): bool =
    n.kind in {nnkProcDef, nnkFuncDef, nnkMethodDef, nnkIteratorDef,
      nnkConverterDef, nnkTemplateDef, nnkMacroDef, nnkLambda, nnkDo}

  proc containsBuffalo(n: NimNode): bool =
    if n == nil:
      return false
    if n.kind == nnkPragmaExpr and n.len >= 2 and pragmaHasBuffalo(n[1]):
      return true
    for c in n:
      if containsBuffalo(c):
        return true
    false

  var buffaloNames: seq[string] = @[]

  proc appendVarDefs(dest: NimNode, defs: NimNode) =
    if defs.kind != nnkIdentDefs or defs.len < 3:
      dest.add(nnkVarSection.newTree(defs.copyNimTree()))
      return
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
      dest.add(nnkVarSection.newTree(defs.copyNimTree()))
      return
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
    dest.add(
      nnkVarSection.newTree(
        nnkIdentDefs.newTree(
          newName, typNode.copyNimTree(), valNode.copyNimTree()
        )
      )
    )
    dest.add(
      nnkCall.newTree(
        nnkDotExpr.newTree(target.copyNimTree(), ident("clear"))
      )
    )

  proc rewriteNode(n: NimNode): NimNode
  proc rewriteStmtList(s: NimNode): NimNode =
    result = newStmtList()
    for stmt in s:
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
        result.add(stmt.copyNimTree())
      elif stmt.kind == nnkVarSection:
        for defs in stmt:
          appendVarDefs(result, defs)
      elif isRoutineDef(stmt):
        if containsBuffalo(stmt):
          error(
            "buffalo: {.buffalo.} inside a nested routine needs its own inner buffaloScope",
            stmt,
          )
        result.add(stmt.copyNimTree())
      else:
        result.add(rewriteNode(stmt))

  proc rewriteNode(n: NimNode): NimNode =
    if n == nil:
      return n
    if n.kind == nnkStmtList:
      return rewriteStmtList(n)
    if isRoutineDef(n):
      if containsBuffalo(n):
        error(
          "buffalo: {.buffalo.} inside a nested routine needs its own inner buffaloScope",
          n,
        )
      return n.copyNimTree()
    if n.kind in {nnkVarSection, nnkLetSection}:
      # Only reachable outside a StmtList (unusual); keep copy to avoid
      # breaking single-node expectations. Normal decls are expanded in
      # `rewriteStmtList`.
      return n.copyNimTree()
    if n.len == 0:
      return n.copyNimTree()
    result = n.copyNimTree()
    for i in 0 ..< result.len:
      result[i] = rewriteNode(result[i])
    return result

  result = rewriteStmtList(body)
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
