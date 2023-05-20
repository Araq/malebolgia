
import malebolgia

proc f() =
  echo "F"

proc g(m: MasterHandle; i: int) {.gcsafe.} =
  if i < 800:
    echo "In g"
    #m.spawn f()

    m.spawn g(m, i+1)
    #m.spawn g(m, i+1)
    echo "G done"

proc main =
  var m = createMaster()
  m.awaitAll:
    m.spawn g(getHandle(m), 0)

main()
