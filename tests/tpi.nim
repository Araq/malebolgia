discard """
  output: '''3.141792613595791'''
"""

import std / [strutils, math, isolation]
import malebolgia

proc term(k: float): float = 4 * math.pow(-1, k) / (2*k + 1)

proc piS(n: int): float =
  var ch = newSeq[float](n+1)
  var m = createMaster()
  m.awaitAll:
    for k in 0..ch.high:
      m.spawn term(float(k)) -> ch[k]
  result = 0.0
  for k in 0..ch.high:
    result += ch[k]

echo formatFloat(piS(5000))
