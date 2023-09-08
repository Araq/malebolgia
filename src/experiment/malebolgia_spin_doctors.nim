# (c) 2023 Andreas Rumpf

import std / [atomics, locks, tasks, times]
from std / os import sleep

import std / isolation
export isolation

const LOCK_IT = true

template withTTASLock(lock: var Atomic[bool]; bode: untyped): untyped =
  withTTASLock lock, LOCK_IT:
    bode

template withTTASLock(lock: var Atomic[bool]; andCond: untyped; bode: untyped): untyped =
  var unlocked = false
  while true:
    if lock.load(moRelaxed):
      cpuRelax()
      continue
    if lock.exchange(true, moAcquire):
      cpuRelax()
      continue
    if not andCond:
      # we unlocked but other condition failed, release it
      lock.store(false, moRelaxed)
      cpuRelax()
      # echo getThreadId(), " unlocked but ", andCond
      continue
    #echo getThreadId(), " unlocked and ", andCond
    break
  try:
    bode
  finally:
    # echo getThreadId(), " released"
    lock.store(false, moRelease)

type
  Master* = object ## Masters can spawn new tasks inside an `awaitAll` block.
    L: Atomic[bool]
    error: string
    runningTasks: int
    stopToken: Atomic[bool]
    shouldEndAt: Time
    usesTimeout: bool


proc `=copy`(dest: var Master; src: Master) {.error.} =
  echo "dolly"
proc `=sink`(dest: var Master; src: Master) {.error.} =
  echo "flushed way"

proc createMaster*(timeout = default(Duration)): Master =
  result = default(Master)
  result.L.store(false, moRelaxed)
  result.stopToken.store(false, moRelaxed)
  if timeout != default(Duration):
    result.usesTimeout = true
    result.shouldEndAt = getTime() + timeout

proc cancel*(m: var Master) =
  ## Try to stop all running tasks immediately.
  ## This cannot fail but it might take longer than desired.
  store(m.stopToken, true, moRelaxed)

proc cancelled*(m: var Master): bool {.inline.} =
  m.stopToken.load(moRelaxed)

proc taskCreated(m: var Master) {.inline.} =
  withTTASLock m.L:
    inc m.runningTasks

proc taskCompleted(m: var Master) {.inline.} =
  withTTASLock m.L:
    dec m.runningTasks

proc stillHaveTime*(m: Master): bool {.inline.} =
  not m.usesTimeout or getTime() < m.shouldEndAt

proc waitForCompletions(m: var Master) =
  var timeoutErr = false
  if not m.usesTimeout:
    withTTASLock m.L, m.runningTasks < 1:
      discard
  else:
    while true:
      if m.L.load(moRelaxed):
        continue
      let success = m.runningTasks == 0
      if success: break
      if getTime() > m.shouldEndAt:
        timeoutErr = true
        break
      sleep(10) # XXX maybe make more precise
  withTTASLock m.L:
    let err = move(m.error)
    if err.len > 0:
      raise newException(ValueError, err)
    elif timeoutErr:
      m.cancel()
      raise newException(ValueError, "'awaitAll' timeout")

# thread pool independent of the 'master':

const
  FixedChanSize {.intdefine.} = 8 ## must be a power of two!
  FixedChanMask = FixedChanSize - 1
  ThreadPoolSize {.intdefine.} = 8 # 24

type
  ThreadState = enum
    tsEmpty
    tsFeeding
    tsToDo
    tsWip
    tsDone
    tsFail
    tsCancel

  PoolTask = object ## a task for the thread pool
    m: ptr Master   ## who is waiting for us
    t: Task         ## what to do
    result: pointer ## where to store the potential result

  FixedChan = object ## channel of a fixed size
    L: Atomic[bool]
    board: array[FixedChanSize, Atomic[ThreadState]]
    data: array[FixedChanSize, PoolTask]

var
  thr: array[ThreadPoolSize, Thread[int]]
  chan: FixedChan
  globalStopToken: Atomic[bool]
  busyThreads: Atomic[int]
  curretThread: Atomic[int]

iterator threads(): int {.inline.} =
  while true:
    #var epoch = getMonoTime()
    var n = curretThread.fetchAdd(1)
    if n == FixedChanSize - 1:
      curretThread.store(0, moRelaxed)
    #echo inNanoseconds(getMonoTime() - epoch)
    yield n

proc send(item: sink PoolTask) =
  # see deques.addLast:
  var 
    done = tsDone
    empty = tsEmpty
    ackchyually = 0

  for i in threads():
    # Test
    if chan.board[i].load(moRelaxed) notin [done, empty]:
      cpuRelax()
      continue

    # Test and Set
    if chan.board[i].compareExchange(done,
        tsFeeding, moAcquire, moRelease):
      ackchyually = i
      break

    # Test and Set
    if chan.board[i].compareExchange(empty,
        tsFeeding, moAcquire, moRelease):
      ackchyually = i
      break
    cpuRelax()

  chan.data[ackchyually] = item
  chan.board[ackchyually].store(tsToDo, moRelease)

proc worker(i: int) {.thread.} =
  var
    item: PoolTask
    todo = tsToDo
    wip  = tsWip
  while not globalStopToken.load(moRelaxed):
    # Test
    if chan.board[i].load(moRelaxed) != todo:
      cpuRelax()
      continue
    # Test and Set
    if not chan.board[i].compareExchange(todo,
        wip, moRelaxed, moRelease):
      cpuRelax()
      continue

    item = move chan.data[i]

    if not item.m.stopToken.load(moRelaxed):
      try:
        atomicInc busyThreads
        item.t.invoke(item.result)
        atomicDec busyThreads
        discard chan.board[i].compareExchange(wip,
          tsDone, moRelease, moRelease)
      except:
        discard chan.board[i].compareExchange(wip,
          tsFail, moRelease, moRelease)
        withTTASLock item.m.L:
          if item.m.error.len == 0:
            let e = getCurrentException()
            item.m.error = "SPAWN FAILURE: [" & $e.name & "] " & e.msg & "\n" & getStackTrace(e)

    # but mark it as completed either way!
    taskCompleted item.m[]

proc setup() =
  chan.L.store(false, moRelaxed)
  globalStopToken.store(false, moRelaxed)
  for i in 0..high(thr):
    chan.board[i].store(tsEmpty, moRelaxed)
    createThread[int](thr[i], worker, i)

proc panicStop*() =
  ## Stops all threads.
  globalStopToken.store(true, moRelaxed)
  joinThreads(thr)

template spawnImplRes[T](master: var Master; fn: typed; res: T) =
  if stillHaveTime(master):
    if busyThreads.load(moRelaxed) < ThreadPoolSize:
      taskCreated master
      send PoolTask(m: addr(master), t: toTask(fn), result: addr res)
    else:
      res = fn

template spawnImplNoRes(master: var Master; fn: typed) =
  if stillHaveTime(master):
    if busyThreads.load(moRelaxed) < ThreadPoolSize:
      taskCreated master
      send PoolTask(m: addr(master), t: toTask(fn), result: nil)
    else:
      fn

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

  const BranchingNodes = {nnkIfStmt, nnkCaseStmt}

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
      if n.kind in BranchingNodes:
        let preExprs = exprs[0..^1]
        for child in items(n):
          var branchExprs = preExprs
          check child, branchExprs, withinLoopB
          exprs.add branchExprs[preExprs.len..^1]
      else:
        for child in items(n): check child, exprs, withinLoopB
        for i in 0..<exprs.len:
          # `==` on NimNode checks if nodes are structurally equivalent.
          # Which is exactly what we need here:
          if exprs[i] == n and n.kind in {nnkSym, nnkIdent}:
            error("re-use of expression '" & repr(n) & "' before 'awaitAll' completed", n)

  var exprs: seq[NimNode] = @[]
  check body, exprs, false
  result = body

template awaitAll*(master: var Master; body: untyped) =
  try:
    checkBody body
  finally:
    waitForCompletions(master)

when not defined(maleSkipSetup):
  setup()

include ".." / malebolgia / masterhandles
