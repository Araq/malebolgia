discard """
  action: "compile"
"""

import std/os
import experiment / malebolgia_push

proc worker(w: ptr Master)=
  while not cancelled(w):
    echo "Triggered"
    os.sleep(3000)

var m: Master = createMaster()

var alreadyStarted = false
m.awaitAll:
  while not cancelled(m):
    stdout.write "Enter command: "
    let userInput = readLine(stdin)
    case userInput
    of "start":
      if alreadyStarted:
        echo "already started"
      else:
        m.spawn worker(addr m)
        alreadyStarted = true
    of "stop":
      echo "Trying to stop"
      m.cancel()
