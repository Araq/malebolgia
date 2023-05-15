
import malebolgia

proc foo =
  echo "foo"

proc bar =
  echo "bar"

proc main =
  var m = createMaster()
  m.awaitAll:
    m.spawn foo()
    for i in 0..<1000:
      m.spawn bar()

main()
