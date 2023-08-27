
import malebolgia
import malebolgia / paralgos

var testData: seq[int] = @[]
for i in 0..<10_000: testData.add i

proc mul4(x: var int) = x *= 4
parMap(testData, 600, mul4)

for i in 0..<10_000: assert testData[i] == i*4

var numbers: seq[int] = @[]
for i in 0..<10_000: numbers.add i

let sum = parReduce(numbers, 600, `+=`)
assert sum == 49995000

var haystack: seq[int] = @[]
for i in 0..<10_000: haystack.add i

template predicate(x): untyped = x == 1000
let idx = parFind(haystack, 600, predicate)
assert idx == 1000
