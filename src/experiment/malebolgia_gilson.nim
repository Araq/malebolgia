import std/monotimes
import std/times
import std/tasks
import std/strutils


### MALEBOLGIA

import malebolgia

# (c) 2023 Andreas Rumpf

import std / [atomics, locks, tasks, times]
from std / os import sleep

import std / isolation
export isolation


const ThreadPoolSize {.intdefine.} = 8 # 24


type
  ## Prevent all the pool from waiting the same resource
  ## That can be summarized at the end
  LockPool[T] = object
    overloaded: bool
    # Happens at the initalization and someone free resource after full
    available: Cond
    # Happens every time we locks[ThreadPoolSize mod 4 == 0]
    halfloaded:Cond
    # Happens every time that all our locks are busy
    full:      Cond
    lock:      Lock
    busy:   array[ThreadPoolSize * 2, bool]
    locks:  array[ThreadPoolSize * 2, Lock]
    values: array[ThreadPoolSize * 2, T]


proc initLockPool*[T](): LockPool[T] =
  result = default(LockPool[T])
  initCond(result.available)
  initCond(result.halfloaded)
  initCond(result.full)
  initLock(result.lock)
  for i in 0..high(result.locks):
    initLock(result.locks[i])
  signal(result.available)


proc deinitLockPool(pool: var LockPool) {.inline.} =
  deinitCond(pool.available)
  deinitCond(pool.halfloaded)
  deinitCond(pool.full)
  deinitLock(pool.lock)
  for i in 0..high(pool.locks):
    deinitLock(pool.locks[i])

## We are not using this but still here as reference
proc acquire[T](pool: var LockPool[T]): int {.inline.} =
  while true:
    for i in 0..high(pool.locks):
      if pool.busy[i]:
        continue
      if not pool.locks[i].tryAcquire:
        continue
      pool.busy[i] = true
      if i mod 4 == 0:
        signal(pool.halfloaded)
      return i

    if tryAcquire(pool.lock):
      pool.overloaded = true
      signal(pool.full)
      wait(pool.available, pool.lock)
      release(pool.lock)
  return -1

proc release[T](pool: var LockPool[T]; pos: int) {.inline.} =
  release(pool.locks[pos])
  pool.busy[pos] = false
  if pos mod 4 == 0 and tryAcquire(pool.lock):
    signal(pool.available)
    release(pool.lock)
  if pool.overloaded and tryAcquire(pool.lock):
    pool.overloaded = false
    signal(pool.available)
    release(pool.lock)


type
  Master* = object ## Masters can spawn new tasks inside an `awaitAll` block.
    c: Cond
    L: Lock
    error: string
    runningTasks: int
    completedTasks: int
    stopToken: Atomic[bool]
    shouldEndAt: Time
    usesTimeout: bool
    pendingTasks: LockPool[int]

proc `=destroy`(m: var Master) {.inline.} =
  deinitCond(m.c)
  deinitLock(m.L)
  deinitLockPool(m.pendingTasks)

proc `=copy`(dest: var Master; src: Master) {.error.}
proc `=sink`(dest: var Master; src: Master) {.error.}

proc createMaster*(timeout = default(Duration)): Master =
  result = default(Master)
  initCond(result.c)
  initLock(result.L)
  var pendingTasks = initLockPool[int]()
  result.pendingTasks = pendingTasks

  if timeout != default(Duration):
    result.usesTimeout = true
    result.shouldEndAt = getTime() + timeout

proc taskCreated(m: var Master;pos: int) {.inline.} =
  m.pendingTasks.busy[pos] = true
  m.pendingTasks.values[pos] = getThreadId()

proc taskCompleted(m: var Master; pos: int) {.inline.} =
  m.pendingTasks.busy[pos] = false
  m.pendingTasks.values[pos] = getThreadId()

proc cancel*(m: var Master) =
  ## Try to stop all running tasks immediately.
  ## This cannot fail but it might take longer than desired.
  store(m.stopToken, true, moRelaxed)

proc cancelled*(m: var Master): bool {.inline.} =
  m.stopToken.load(moRelaxed)

proc stillHaveTime*(m: Master): bool {.inline.} =
  not m.usesTimeout or getTime() < m.shouldEndAt

iterator waitForCompletions(m: var Master): bool =
  var timeoutErr = false
  var pendings = len(m.pendingTasks.locks)
  while pendings > 0:
    pendings = len(m.pendingTasks.locks)
    #echo "busy list: ", m.pendingTasks.busy
    for i in 0..high(m.pendingTasks.locks):
      if m.pendingTasks.busy[i]:
        continue
      if not tryAcquire(m.pendingTasks.locks[i]):
        continue
      # makes sure value is what we tested before the lock
      if m.pendingTasks.busy[i]:
        release(m.pendingTasks.locks[i])
        continue
      m.pendingTasks.values[i] = getThreadId()
      dec(pendings)
      release(m.pendingTasks.locks[i])
    yield false
  yield true
  #
  #  if m.usesTimeout and getTime() > m.shouldEndAt:
  #    timeoutErr = true
  #    break
  #  elif m.usesTimeout:
  #    sleep(10) # XXX maybe make more precise
  let err = move(m.error)
  if err.len > 0:
    raise newException(ValueError, err)
  elif timeoutErr:
    m.cancel()
    raise newException(ValueError, "'awaitAll' timeout")


# thread pool independent of the 'master':
type
  PoolTaskKind = enum
    ptkSlot
    ptkTask

  PoolTask = object ## a task for the thread pool
    case kind: PoolTaskKind
    of ptkTask:
      m: ptr Master   ## who is waiting for us
      t: Task         ## what to do
      result: pointer ## where to store the potential result
    else: discard

  FixedChan = LockPool[PoolTask]

var
  thr: array[ThreadPoolSize-1, Thread[void]] # -1 because the main thread counts too
  chan: FixedChan
  globalStopToken: Atomic[bool]


proc acquireSlot(pool: var LockPool[PoolTask]; waitable: bool = true; attempts: int = 2): int {.inline.} =
  result = -1
  var executions = attempts
  while true:
    dec executions
    for i in 0..high(pool.locks):
      if pool.busy[i]:
        continue
      if pool.values[i].kind == ptkTask:
        continue
      if not pool.locks[i].tryAcquire:
        continue
      if pool.values[i].kind == ptkTask:
        release(pool.locks[i])
        continue
      pool.busy[i] = true
      if i mod 4 == 0:
        signal(pool.halfloaded)
      return i
    pool.overloaded = true

    if tryAcquire(pool.lock):
      release(pool.lock)

    if executions == 0 and not waitable:
      return -1
      
    if executions == 0:
      executions = attempts
      if tryAcquire(pool.lock):
        #echo "waiting more slots ", getThreadId(), " locked"
        wait(pool.available, pool.lock)
        release(pool.lock)
      else:
        # if thread is locked someone is waiting for this
        signal(pool.halfloaded)



proc acquireTask(pool: var LockPool[PoolTask]; waitable: bool = true; attempts: int = 4): int {.inline.} =
  result = -1
  var executions = attempts
  while true:
    dec executions
    for i in 0..high(pool.locks):
      if pool.busy[i]:
        continue
      if pool.values[i].kind == ptkSlot:
        continue
      if not pool.locks[i].tryAcquire:
        continue
      if pool.values[i].kind == ptkSlot:
        release(pool.locks[i])
        continue
      pool.busy[i] = true
      return i

    if executions == 0 and not waitable:
      return -1

    if executions == 0:
      executions = attempts
      if tryAcquire(pool.lock):
        #echo "waiting more tasks ", getThreadId(), " locked"
        wait(pool.halfloaded, pool.lock)
        release(pool.lock)
      else:
        #echo "waiting more tasks ", getThreadId()
        acquire(pool.lock)
        release(pool.lock)
      #echo "receive more tasks ", getThreadId()

proc send(item: sink PoolTask) =
  var pos = acquireSlot(chan)
  # if pos < 0:
  #   var kinds = [ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot]
  #   for i in 0..high(chan.locks):
  #     if chan.values[i].kind == ptkTask:
  #       signal(chan.halfloaded)
  #     kinds[i] = chan.values[i].kind
  #   echo "No slots see ", kinds
  #   pos = acquireSlot(chan)

  item.m[].taskCreated(pos)
  chan.values[pos] = move item
  release chan, pos

proc worker() {.thread.} =
  var item = PoolTask(kind: ptkSlot)
  while not globalStopToken.load(moRelaxed):
    var pos = acquireTask(chan)
    # if pos < 0:
    #   var kinds = [ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot,ptkSlot]
    #   for i in 0..high(chan.locks):
    #     kinds[i] = chan.values[i].kind
    #   echo "No tasks see ", kinds
    #   pos = acquireTask(chan, true)
    item = move chan.values[pos]
    chan.values[pos] = PoolTask(kind: ptkSlot)
    try:
      if item.m.stopToken.load(moRelaxed):
        break
      item.t.invoke(item.result)
    except:
      acquire(item.m.L)
      if item.m.error.len == 0:
        let e = getCurrentException()
        item.m.error = "SPAWN FAILURE: [" & $e.name & "] " & e.msg & "\n" & getStackTrace(e)
      release(item.m.L)
    finally:
      taskCompleted(item.m[], pos)
      release chan, pos


proc setup() =
  chan = initLockPool[PoolTask]()
  for i in 0..high(thr): createThread[void](thr[i], worker)

proc panicStop*() =
  ## Stops all threads.
  globalStopToken.store(true, moRelaxed)
  joinThreads(thr)
  deinitLockPool(chan)

template spawnImplRes[T](master: var Master; fn: typed; res: T) =
  if stillHaveTime(master):
    send PoolTask(kind: ptkTask, m: addr(master), t: toTask(fn), result: addr res)

template spawnImplNoRes(master: var Master; fn: typed) =
  if stillHaveTime(master):
    send PoolTask(kind: ptkTask, m: addr(master), t: toTask(fn), result: nil)

import std / macros

macro spawn*(a: Master; b: untyped) =
  if b.kind in nnkCallKinds and b.len == 3 and b.eqIdent("->"):
    result = newCall(bindSym"spawnImplRes", a, b[1], b[2])
  else:
    result = newCall(bindSym"spawnImplNoRes", a, b)

macro checkBody(body: untyped): untyped =
  const DeclarativeNodes = {nnkTypeSection, nnkFormalParams, nnkGenericParams,
    nnkMacroDef, nnkTemplateDef, nnkConstSection, nnkConstDef,
    nnkIncludeStmt, nnkImportStmt,
    nnkExportStmt, nnkPragma, nnkCommentStmt,
    nnkTypeOfExpr, nnkMixinStmt, nnkBindStmt}

  const BranchingNodes = {nnkIfStmt, nnkCaseStmt}

  proc isSpawn(n: NimNode): bool =
    n.eqIdent("spawn") or (n.kind == nnkDotExpr and n[1].eqIdent("spawn"))

  proc check(n: NimNode; exprs: var seq[NimNode]; withinLoop: bool) =
    if n.kind in nnkCallKinds and isSpawn(n):
      let b = n[^1]
      for i in 1 ..< n.len:
        check n[i], exprs, withinLoop
      if b.kind in nnkCallKinds and b.len == 3 and b.eqIdent("->"):
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
    for completed in master.waitForCompletions:
      signal(chan.halfloaded)
      let hasTasks = acquireTask(chan, false, ThreadPoolSize)
      if hasTasks < 0:
        # this is an ERROR
        # means master thinks we are not done
        # but there are no tasks scheduled
        break
      else:
        release(chan, hasTasks)


when not defined(maleSkipSetup):
  setup()


### PAR ALGOS

template `@!`[T](data: openArray[T]; i: int): untyped =
  cast[ptr UncheckedArray[T]](addr data[i])

template parMap*[T](data: var openArray[T]; bulkSize: int; op: untyped) =
  proc work(a: ptr UncheckedArray[T]; until: int) =
    for i in 0..<until: op a[i]
  var m = createMaster()
  m.awaitAll:
    var i = 0
    while i+bulkSize <= data.len:
      m.spawn work(data@!i, bulkSize)
      i += bulkSize
    if i < data.len:
      m.spawn work(data@!i, data.len-i)


### BENCHMARK

proc now(i: var MonoTime) {.inline.} =
  i = getMonoTime()


proc hello*(i: var string) {.inline.} =
  i = "World"


let sep  = "\t"
let runs = 1000
echo [
  "OP",
  "T0E0",
  "T0E1",
  "T1E0",
  "T1E1",
  "T2E0",
  "T0E1-T0E0",
  "T1E0-T0E1",
].join(sep)

for i in 0..runs:
  var 
    bigbang = getMonoTime()
    epoch   = getMonoTime()
    ops = [epoch, epoch, epoch, epoch, epoch]

    ## Overloading test
    ##
    # ops = [
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch
    # ]
  
  bigbang = getMonoTime()
  epoch   = getMonoTime()
  parMap ops, 2, now
  
  echo [
    $inNanoseconds(epoch  - bigbang),  # mesurement precision
    $inNanoseconds(ops[0] - epoch),    # how fast we perform 1º task
    $inNanoseconds(ops[1] - epoch),    # how fast we perform 2º task serial after 1º
    $inNanoseconds(ops[2] - epoch),    # how fast we perform 3º task parallel
    $inNanoseconds(ops[3] - epoch),    # how fast we perform 4º task serial after 3º
    $inNanoseconds(ops[4] - epoch),    # how fast we perform 5º task parallel
    $inNanoseconds(ops[1] - ops[0]),   # serial   latency
    $inNanoseconds(ops[3] - ops[1]),   # parallel latency
  ].join(sep)

  ## this helps checks for early termination
  ## when waitAll say its done isn't true
  #
  # var ops = ["hello", "hello", "hello", "hello", "hello"]
  # parMap ops, 2, hello
  # echo $ops
