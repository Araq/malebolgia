discard """
  errormsg: "re-use of expression 'res' before 'awaitAll' completed"
  line: 19
"""

import malebolgia

import std / [isolation]

proc g(i: int): int =
  result = 1

proc main =
  var m = createMaster()
  var res: int
  m.awaitAll:
    #m.spawn g(0) -> res
    for i in 0..3:
      m.spawn g(0) -> res # <-- error here

  echo "final result ", res

main()
