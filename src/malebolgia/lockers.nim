# (c) 2023 Andreas Rumpf

import ticketlocks

type
  LockerOnStack[T] = object # we keep the data on the stack
    raw: T
    L: TicketLock

  Locker*[T] = object
    p: ptr LockerOnStack[T]

# Does not work yet due to the hidden `isolate` calls.
# XXX Investigate why that is.
#proc `=copy`[T](dest: var Locker[T]; src: Locker[T]) {.error.}
#proc `=sink`[T](dest: var Locker[T]; src: Locker[T]) {.error.}

template initLocker*[T](x: T): Locker[T] =
  var onStack = LockerOnStack[T](raw: x, L: initTicketLock())
  Locker[T](p: addr onStack)

func extract*[T](src: Locker[T]): T {.inline.} =
  ## Returns the internal value of `src`.
  ## The value is moved from `src`.
  result = move(src.p.raw)

import macros

proc rep(n: NimNode; local: string; by: NimNode): NimNode =
  case n.kind
  of nnkSym, nnkOpenSymChoice, nnkClosedSymChoice, nnkIdent:
    if n.eqIdent(local):
      result = copyNimTree(by)
    else:
      result = n
  else:
    result = copyNimNode(n)
    for i in 0..<n.len:
      result.add rep(n[i], local, by)

macro lock*[T](m: Locker[T]; body: untyped) =
  if m.len == 2 and m[0].kind == nnkDiscardStmt:
    expectKind m, nnkStmtListExpr
    expectLen m, 2
    expectKind m[0], nnkDiscardStmt
    let local = m[0][0].strVal
    let mon = m[1]
    #echo repr m
    #echo repr body
    let by = newTree(nnkDotExpr, newTree(nnkDotExpr, mon, ident"p"), ident"raw")
    let action = rep(body, local, by)
    result = quote do:
      acquire(`mon`.p.L)
      try:
        `action`
      finally:
        release(`mon`.p.L)
  else:
    result = quote do:
      acquire(`m`.p.L)
      try:
        `body`
      finally:
        release(`m`.p.L)

macro unprotected*[T](m: Locker[T]; body: untyped) =
  expectKind m, nnkStmtListExpr
  expectLen m, 2
  expectKind m[0], nnkDiscardStmt
  let local = m[0][0].strVal
  let mon = m[1]
  let by = newTree(nnkDotExpr, newTree(nnkDotExpr, mon, ident"p"), ident"raw")
  result = rep(body, local, by)

template `as`*[T](m: Locker[T]; name: untyped): Locker[T] = (discard astToStr(name); m)

when isMainModule:
  import std / tables
  var monit = initLocker(initTable[string, int]())
  lock monit as x:
    x["f"] = 90

  lock monit as x:
    x["g"] = 100

  unprotected monit as x:
    echo x

  #echo monit.extract
