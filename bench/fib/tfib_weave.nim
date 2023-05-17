
import weave

proc fib(n: int): int {.gcsafe.} =
  if n < 2:
    return n

  let x = spawn fib(n-1)
  let y = fib(n-2)

  result = sync(x) + y

proc main() =
  var n = 40

  init(Weave)
  let f = fib(n)
  exit(Weave)

  echo f

import std / times

let t0 = getTime()
main()
echo "took ", getTime() - t0
