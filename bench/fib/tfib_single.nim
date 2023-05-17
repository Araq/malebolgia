
proc fib(n: int): int {.gcsafe.} =
  if n < 2:
    return n
  let a = fib(n-1)
  let b = fib(n-2)
  result = a + b

proc main() =
  var n = 40
  let f = fib(n)
  echo f

import std / times

let t0 = getTime()
main()
echo "took ", getTime() - t0
