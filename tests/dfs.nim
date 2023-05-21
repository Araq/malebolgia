
import malebolgia

proc dfs(depth, breadth: int): int {.gcsafe.} =
  if depth == 0: return 1

  var sums = newSeq[int](breadth)

  var m = createMaster()
  m.awaitAll:
    for i in 0 ..< breadth:
      m.spawn dfs(depth - 1, breadth) -> sums[i]

  result = 0
  for i in 0 ..< breadth:
    result += sums[i]

let answer = dfs(8, 8)
echo answer
