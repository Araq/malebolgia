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

type
  Master* = object ## Masters can spawn new tasks inside an `awaitAll` block.
    c: Cond
    L: Lock
    error: string
    runningTasks: int
    completedTasks: Atomic[int]
    stopToken: Atomic[bool]
    shouldEndAt: Time
    usesTimeout: bool

proc `=destroy`(m: var Master) {.inline.} =
  deinitCond(m.c)
  deinitLock(m.L)

proc `=copy`(dest: var Master; src: Master) {.error.}
proc `=sink`(dest: var Master; src: Master) {.error.}

proc createMaster*(timeout = default(Duration)): Master =
  result = default(Master)
  initCond(result.c)
  initLock(result.L)

  result.completedTasks.store(0, moRelaxed)
  if timeout != default(Duration):
    result.usesTimeout = true
    result.shouldEndAt = getTime() + timeout

proc cancel*(m: var Master) =
  ## Try to stop all running tasks immediately.
  ## This cannot fail but it might take longer than desired.
  store(m.stopToken, true, moRelaxed)

proc cancelled*(m: var Master): bool {.inline.} =
  m.stopToken.load(moRelaxed)

proc taskCompleted(m: var Master) {.inline.} =
  m.completedTasks.atomicInc
  if m.runningTasks == m.completedTasks.load(moRelaxed):
    signal(m.c)

proc stillHaveTime*(m: Master): bool {.inline.} =
  not m.usesTimeout or getTime() < m.shouldEndAt

proc waitForCompletions(m: var Master) =
  var timeoutErr = false
  if not m.usesTimeout:
    while m.runningTasks > m.completedTasks.load(moRelaxed):
      wait(m.c, m.L)
  else:
    while true:
      let success = m.runningTasks > m.completedTasks.load(moRelaxed)
      if success: break
      if getTime() > m.shouldEndAt:
        timeoutErr = true
        break
      sleep(10) # XXX maybe make more precise
  let err = move(m.error)
  if err.len > 0:
    raise newException(ValueError, err)
  elif timeoutErr:
    m.cancel()
    raise newException(ValueError, "'awaitAll' timeout")

# thread pool independent of the 'master':

const
  FixedChanSize {.intdefine.} = 16 ## must be a power of two!
  FixedChanMask = FixedChanSize - 1

  ThreadPoolSize {.intdefine.} = 8 # 24

type
  PoolTask = object ## a task for the thread pool
    m: ptr Master   ## who is waiting for us
    t: Task         ## what to do
    result: pointer ## where to store the potential result

  FixedChan = object ## channel of a fixed size
    spaceAvailable, dataAvailable: Cond
    L: Lock
    data: array[FixedChanSize, PoolTask]
    lock: array[FixedChanSize, Lock]
    todo: array[FixedChanSize, bool]

var
  thr: array[ThreadPoolSize-1, Thread[void]] # -1 because the main thread counts too
  chan: FixedChan
  globalStopToken: Atomic[bool]

proc send(item: sink PoolTask) =
  # see deques.addLast:
  while true:
    for i in 0..high(chan.lock):
      if not tryAcquire(chan.lock[i]):
        continue
      if chan.todo[i]:
        chan.lock[i].release
        continue
      chan.data[i] = item
      chan.todo[i] = true
      chan.lock[i].release
      return
    signal(chan.dataAvailable)
    # TODO: I removed the feature of busyThreads that runs in current instead of wait
    wait(chan.spaceAvailable, chan.L)


proc worker() {.thread.} =
  var item: PoolTask
  while not globalStopToken.load(moRelaxed):
    for i in 0..high(chan.lock):
      let before = getMonoTime()
      if not tryAcquire(chan.lock[i]):
        continue
      if not chan.todo[i]:
        chan.lock[i].release
        continue
      item = move chan.data[i]
      if item.m.stopToken.load(moRelaxed):
        chan.lock[i].release
        break
      try:
        item.t.invoke(item.result)
      except:
        acquire(item.m.L)
        if item.m.error.len == 0:
          let e = getCurrentException()
          item.m.error = "SPAWN FAILURE: [" & $e.name & "] " & e.msg & "\n" & getStackTrace(e)
        release(item.m.L)
      finally:
        chan.todo[i] = false
        chan.lock[i].release
        signal(chan.spaceAvailable)
        # but mark it as completed either way!
        taskCompleted item.m[]
    wait(chan.dataAvailable, chan.L)

proc setup() =
  initCond(chan.dataAvailable)
  initCond(chan.spaceAvailable)
  initLock(chan.L)
  for i in 0..high(thr): createThread[void](thr[i], worker)
  for i in 0..high(chan.lock):
    initLock(chan.lock[i])
    chan.todo[i] = false

proc panicStop*() =
  ## Stops all threads.
  globalStopToken.store(true, moRelaxed)
  joinThreads(thr)
  deinitCond(chan.dataAvailable)
  deinitCond(chan.spaceAvailable)
  deinitLock(chan.L)
  for i in 0..high(chan.lock): deinitLock(chan.lock[i])

template spawnImplRes[T](master: var Master; fn: typed; res: T) =
  if stillHaveTime(master):
    master.runningTasks += 1
    send PoolTask(m: addr(master), t: toTask(fn), result: addr res)

template spawnImplNoRes(master: var Master; fn: typed) =
  if stillHaveTime(master):
    master.runningTasks += 1
    send PoolTask(m: addr(master), t: toTask(fn), result: nil)

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
    signal(chan.dataAvailable)
    waitForCompletions(master)

when not defined(maleSkipSetup):
  setup()


### PARALGOS

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
let runs = 100
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

var 
  bigbang = getMonoTime()
  epoch   = getMonoTime()
  ops = [epoch, epoch, epoch, epoch, epoch]
  #ops = ["hello", "hello", "hello", "hello", "hello"]


for i in 0..runs:
  bigbang = getMonoTime()
  epoch   = getMonoTime()
  parMap ops, 2, now

  echo [
    $inNanoseconds(epoch  - bigbang),
    $inNanoseconds(ops[0] - epoch),
    $inNanoseconds(ops[1] - epoch),
    $inNanoseconds(ops[2] - epoch),
    $inNanoseconds(ops[3] - epoch),
    $inNanoseconds(ops[4] - epoch),
    $inNanoseconds(ops[1] - ops[0]),
    $inNanoseconds(ops[3] - ops[1]),
  ].join(sep)

  #parMap ops, 2, hello
  #echo $ops
