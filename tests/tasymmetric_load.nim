import malebolgia

import std/[os, atomics]

malebolgiaSetup(numThr = 20)

var
  threadpool = createMaster(activeProducer = true)
  busyThreads: Atomic[int]
busyThreads.store 0

let mainThreadId = getThreadId()

proc findStartPositionsAndPlay() =
  atomicInc busyThreads
  echo "Started. Busy threads: ", busyThreads.load

  sleep(1000)
  if getThreadId() == mainThreadId:
    sleep(10_000)

  atomicDec busyThreads
  echo "Finished. Busy threads: ", busyThreads.load

threadpool.awaitAll:
  for i in 1 .. 10000:
    threadpool.spawn findStartPositionsAndPlay()
