
import malebolgia_opt
import std / isolation

proc f() =
  echo "F"

proc g(m: ptr Master; i: int) {.gcsafe.} =
  if i < 800:
    echo "In g"
    #m[].spawn f()

    m[].spawn g(m, i+1)
    #m[].spawn g(m, i+1)
    echo "G done"

proc main =
  var m = createMaster()
  m.awaitAll:
    m.spawn g(addr m, 0)

main()
