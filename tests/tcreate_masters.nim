
import malebolgia

import malebolgia / ticketlocks

import std / [os, isolation]

var
  counter: int
  counterLock: TicketLock

proc f() =
  echo "F"
  #sleep 50
  withLock counterLock:
    inc counter

proc g(i: int): int {.gcsafe.} =
  if i < 8:
    echo "level open ", i
    var m = createMaster()
    var resA, resB: int
    m.awaitAll:
      m.spawn f()
      m.spawn g(i+1) -> resA
      m.spawn g(i+1) -> resB
      echo "waiting for ", i
    result = resA + resB

    echo "level done ", i
  else:
    result = 1

proc main =
  var m = createMaster()
  var res: int
  m.awaitAll:
    m.spawn g(0) -> res

  echo "counter ", counter
  echo "final result ", res

main()
