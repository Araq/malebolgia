## The objective of this benchmark is check how much time it looses
## from running some operation in other thread, instead of using same.
##
## This may be better as a tool to mesure malebolgia evolution than as
## benchmark with other similar frameworks
##
## Flaws:
## parApply has some setup


import std/[times, monotimes, strutils]
import malebolgia

var 
  bigbang = getMonoTime()
  epoch   = getMonoTime()


template `@!`[T](data: openArray[T]; i: int): untyped =
  cast[ptr UncheckedArray[T]](addr data[i])

template parApply*[T](data: var openArray[T]; bulkSize: int; op: untyped) =
  ##[ Applies `op` on every element of `data`, `op(data[i)` in parallel.
  `bulkSize` specifies how many elements are processed sequentially
  and not in parallel because sending a task to a different thread
  is expensive. `bulkSize` should probably be larger than you think but
  it depends on how expensive the operation `op` is.]##
  proc worker(a: ptr UncheckedArray[T]; until: int) =
    for i in 0..<until: op a[i]

  var m = createMaster()
  m.awaitAll:
    var i = 0
    ## We reset epoch get values without createMaster/waitAll interference
    epoch   = getMonoTime()
    ##
    while i+bulkSize <= data.len:
      m.spawn worker(data@!i, bulkSize)
      i += bulkSize
    if i < data.len:
      m.spawn worker(data@!i, data.len-i)


proc now(i: var MonoTime) {.inline.} =
  i = getMonoTime()


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
var ops = [getMonoTime(), getMonoTime(), getMonoTime(), getMonoTime(), getMonoTime()]
for i in 0..<runs:
  var
    ops = [epoch, epoch, epoch, epoch, epoch]

    # Overloading test
    #
    # ops = [
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch,
    #     epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch
    # ]
  
  bigbang = getMonoTime()
  parApply ops, 2, now
  
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
