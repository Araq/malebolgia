## (c) 2023 Andreas Rumpf

import std / [atomics, locks, tasks, times]
from std / os import sleep

type
  Master* = object ## Masters can spawn new tasks inside an `awaitAll` block.
    L: Lock
    error: string
    runningTasks: Atomic[int]
    stopToken: Atomic[bool]
    shouldEndAt: Time
    usesTimeout: bool

proc `=destroy`(m: var Master) {.inline.} =
  deinitLock(m.L)

proc `=copy`(dest: var Master; src: Master) {.error.}
proc `=sink`(dest: var Master; src: Master) {.error.}

proc createMaster*(timeout = default(Duration)): Master =
  result = default(Master)
  initLock(result.L)
  if timeout != default(Duration):
    result.usesTimeout = true
    result.shouldEndAt = getTime() + timeout

proc abort*(m: var Master) =
  ## Try to stop all running tasks immediately.
  ## This cannot fail but it might take longer than desired.
  store(m.stopToken, true, moRelaxed)

proc taskCreated(m: var Master) {.inline.} =
  atomicInc m.runningTasks

proc taskCompleted(m: var Master) {.inline.} =
  atomicDec m.runningTasks

proc stillHaveTime*(m: Master): bool {.inline.} =
  not m.usesTimeout or getTime() < m.shouldEndAt

# thread pool independent of the 'master':

const
  FixedChanSize {.intdefine.} = 4 ## must be a power of two!
  FixedChanMask = FixedChanSize - 1

  ThreadPoolSize {.intdefine.} = 8 # 256
  ThreadPoolMask = ThreadPoolSize - 1

type
  PoolTask = object ## a task for the thread pool
    m: ptr Master   ## who is waiting for us
    t: Task         ## what to do
    result: pointer ## where to store the potential result

  FixedChan = object ## channel of a fixed size
    dataAvailable: Cond
    L: Lock
    head, tail, count: int
    data: array[FixedChanSize, PoolTask]

var
  thr: array[ThreadPoolSize, Thread[int]]
  chans: array[ThreadPoolSize, FixedChan]
  globalStopToken: Atomic[bool]

proc trySend(chan: var FixedChan; master: var Master; item: sink PoolTask): bool =
  # see deques.addLast:
  acquire(chan.L)
  if chan.count < FixedChanSize:
    inc chan.count
    chan.data[chan.tail] = item
    chan.tail = (chan.tail + 1) and FixedChanMask
    signal(chan.dataAvailable)
    release(chan.L)
    taskCreated master
    result = true
  else:
    release(chan.L)
    result = false

var myself {.threadvar.}: int

proc probeWorkers(): int =
  # round robin scheduling, but starting with our direct neighbor:
  var i = (myself + 1) and ThreadPoolMask
  while i != myself:
    if chans[i].count < FixedChanSize:
      # XXX .load(moRelaxed) < FixedChanSize:
      return i
    i = (i + 1) and ThreadPoolMask
  return -1

proc interestingChan(key: ptr Master; chan: var FixedChan): bool =
  acquire(chan.L)
  result = false
  var tail = chan.tail
  for i in 0..<chan.count:
    if chan.data[tail].m == key:
      result = true
      break
    tail = (tail + 1) and FixedChanMask
  release(chan.L)

proc whomToStealFrom(m: ptr Master): int =
  # we need to steal from the thread which has a task in its queue
  # that refers to our master!
  var i = (myself + 1) and ThreadPoolMask
  while i != myself:
    if interestingChan(m, chans[i]):
      return i
    i = (i + 1) and ThreadPoolMask
  # or else we try to steal from ourselves:
  return myself

proc runSingleItem(item: PoolTask) =
  if not item.m.stopToken.load(moRelaxed):
    try:
      item.t.invoke(item.result)
    except:
      acquire(item.m.L)
      if item.m.error.len == 0:
        let e = getCurrentException()
        item.m.error = "SPAWN FAILURE: [" & $e.name & "] " & e.msg & "\n" & getStackTrace(e)
      release(item.m.L)
  # but mark it as completed either way!
  taskCompleted item.m[]

proc drain(chan: var FixedChan) =
  var items: array[FixedChanSize, PoolTask]
  var itemsLen = 0
  while chan.count > 0:
    # see deques.popFirst:
    dec chan.count
    items[itemsLen] = move chan.data[chan.head]
    inc itemsLen
    chan.head = (chan.head + 1) and FixedChanMask
  release(chan.L)
  for i in 0..<itemsLen:
    runSingleItem(items[i])

proc worker(self: int) {.thread.} =
  myself = self
  var item: PoolTask
  while not globalStopToken.load(moRelaxed):
    acquire(chans[self].L)
    while chans[self].count == 0:
      wait(chans[self].dataAvailable, chans[self].L)
    drain chans[self]


proc setup() =
  for i in 0..high(thr):
    createThread(thr[i], worker, i)
    initCond(chans[i].dataAvailable)
    initLock(chans[i].L)


proc panicStop*() =
  ## Stops all threads.
  globalStopToken.store(true, moRelaxed)
  joinThreads(thr)
  for i in 0..high(thr):
    deinitCond(chans[i].dataAvailable)
    deinitLock(chans[i].L)

template spawnImplRes[T](master: var Master; fn: typed; res: T) =
  if stillHaveTime(master):
    let w = probeWorkers()
    if w >= 0 and trySend(chans[w], master, PoolTask(m: addr(master), t: toTask(fn), result: addr res)):
      discard
    else:
      res = fn

template spawnImplNoRes(master: var Master; fn: typed) =
  if stillHaveTime(master):
    let w = probeWorkers()
    if w >= 0 and trySend(chans[w], master, PoolTask(m: addr(master), t: toTask(fn), result: nil)):
      discard
    else:
      fn

proc busyWaitForCompletions(m: var Master) =
  var timeoutErr = false
  while true:
    let success = m.runningTasks.load(moRelaxed) == 0
    if success: break
    if m.usesTimeout and getTime() > m.shouldEndAt:
      timeoutErr = true
      break
    let w = whomToStealFrom(addr m)
    acquire(chans[w].L)
    drain(chans[w])
    #[
    elif m.usesTimeout:
      sleep(10) # XXX maybe make more precise
    else:
      acquire(m.L)
      while m.runningTasks > 0:
        wait(m.c, m.L)
      release(m.L)
      # after the condition variable we know that m.runningTasks == 0
      # so that we can skip the 'if success: break':
      break ]#
  acquire(m.L)
  let err = move(m.error)
  release(m.L)
  if err.len > 0:
    raise newException(ValueError, err)
  elif timeoutErr:
    m.abort()
    raise newException(ValueError, "'awaitAll' timeout")

import std / macros

macro spawn*(a: Master; b: untyped) =
  if b.kind in nnkCallKinds and b.len == 3 and b[0].eqIdent("->"):
    result = newCall(bindSym"spawnImplRes", a, b[1], b[2])
  else:
    result = newCall(bindSym"spawnImplNoRes", a, b)

macro checkBody(body: untyped): untyped =
  # We check here for dangerous "too early" access of memory locations that
  # are "already" gone.
  # For example:
  #
  # m.awaitAll:
  #    m.spawn g(i+1) -> resA
  #    m.spawn g(i+1) -> resA # <-- store into the same location without protection!

  const DeclarativeNodes = {nnkTypeSection, nnkFormalParams, nnkGenericParams,
    nnkMacroDef, nnkTemplateDef, nnkConstSection, nnkConstDef,
    nnkIncludeStmt, nnkImportStmt,
    nnkExportStmt, nnkPragma, nnkCommentStmt,
    nnkTypeOfExpr, nnkMixinStmt, nnkBindStmt}

  proc isSpawn(n: NimNode): bool =
    n.eqIdent("spawn") or (n.kind == nnkDotExpr and n[1].eqIdent("spawn"))

  proc check(n: NimNode; exprs: var seq[NimNode]; withinLoop: bool) =
    if n.kind in nnkCallKinds and isSpawn(n[0]):
      let b = n[^1]
      for i in 1 ..< n.len:
        check n[i], exprs, withinLoop
      if b.kind in nnkCallKinds and b.len == 3 and b[0].eqIdent("->"):
        let dest = b[2]
        exprs.add dest
        if withinLoop and dest.kind in {nnkSym, nnkIdent}:
          error("re-use of expression '" & $dest & "' before 'awaitAll' completed", dest)

    elif n.kind in DeclarativeNodes:
      discard "declarative nodes are not interesting"
    else:
      let withinLoopB = withinLoop or n.kind in {nnkWhileStmt, nnkForStmt}
      for child in items(n): check child, exprs, withinLoopB
      for i in 0..<exprs.len:
        # `==` on NimNode checks if nodes are structurally equivalent.
        # Which is exactly what we need here:
        if exprs[i] == n:
          error("re-use of expression '" & $n & "' before 'awaitAll' completed", n)

  var exprs: seq[NimNode] = @[]
  check body, exprs, false
  result = body

template awaitAll*(master: var Master; body: untyped) =
  try:
    checkBody body
  finally:
    busyWaitForCompletions(master)

when not defined(maleSkipSetup):
  setup()
