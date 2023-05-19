
import malebolgia
import std / isolation

proc foo =
  echo "foo"

proc bar(s: string) =
  echo "bar ", s

proc main =
  var m = createMaster()
  m.awaitAll:
    m.spawn foo()
    for i in 0..<1000:
      m.spawn bar($i)
      if i == 300: m.cancel()

main()
