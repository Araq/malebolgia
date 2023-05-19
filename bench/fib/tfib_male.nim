
#import experiment / malebolgia_push
import malebolgia
import std / isolation

proc fib(n: int): int {.gcsafe.} =
  if n < 2:
    return n
  var m = createMaster()
  var a, b: int
  m.awaitAll:
    m.spawn fib(n-1) -> a
    b = fib(n-2)
  result = a + b

proc main() =
  var n = 40
  let f = fib(n)
  echo f

import std / monotimes

let t0 = getMonoTime()
main()
echo "took ", getMonoTime() - t0
