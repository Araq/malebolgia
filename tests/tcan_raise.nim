
import malebolgia
import std / isolation

proc f() =
  echo "F"

proc g(m: ptr Master; i: int) {.gcsafe.} =
  if i < 10:
    echo "In g"
    m[].spawn f()

    m[].spawn g(m, i+1)
    m[].spawn g(m, i+1)
    echo "G done"
  else:
    raise newException(IndexError, "bad index")

proc main =
  var m = createMaster()
  m.awaitAll:
    m.spawn g(addr m, 0)

main()
