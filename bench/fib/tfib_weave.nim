
import weave

proc fib(n: int): int {.gcsafe.} =
  if n < 2:
    return n

  let x = spawn fib(n-1)
  let y = fib(n-2)

  result = sync(x) + y

proc main() =
  var n = 40
  let f = fib(n)
  echo f

import std / monotimes

init(Weave)

let t0 = getMonoTime()
main()
echo "took ", getMonoTime() - t0
exit(Weave)
