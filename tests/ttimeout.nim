import std / [atomics, os, times]
import malebolgia

proc finishAfterCancellation(master: MasterHandle; started, finished: ptr Atomic[bool]) {.gcsafe.} =
  store(started[], true, moRelaxed)
  while not master.cancelled:
    sleep(1)
  sleep(100)
  store(finished[], true, moRelaxed)

proc main() =
  var m = createMaster(timeout = initDuration(milliseconds = 500))
  var started, finished: Atomic[bool]
  var timedOut = false

  try:
    m.awaitAll:
      m.spawn finishAfterCancellation(m.getHandle, addr started, addr finished)
  except ValueError as e:
    timedOut = e.msg == "'awaitAll' timeout"

  doAssert timedOut
  doAssert load(started, moRelaxed), "task did not start before timeout"
  doAssert load(finished, moRelaxed), "awaitAll returned before its task completed"

main()
