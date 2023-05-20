discard """
  action: "compile"
"""

import std/os
import malebolgia

proc worker(w: MasterHandle)=
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
        m.spawn worker(m.getHandle)
        alreadyStarted = true
    of "stop":
      echo "Trying to stop"
      m.cancel()
