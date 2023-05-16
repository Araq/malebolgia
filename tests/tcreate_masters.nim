
import malebolgia

import malebolgia / ticketlocks

import std / [os, isolation]

var
  counter: int
  counterLock: TicketLock

proc f() =
  echo "F"
  #sleep 50
  acquire counterLock
  inc counter
  release counterLock

proc g(i: int) {.gcsafe.} =
  if i < 8:
    echo "level open ", i
    var m = createMaster()
    m.awaitAll:
      m.spawn f()
      m.spawn g(i+1)
      m.spawn g(i+1)
      echo "waiting for ", i

    echo "level done ", i

proc main =
  var m = createMaster()
  m.awaitAll:
    m.spawn g(0)

  echo "counter ", counter

main()
