
import std / [strutils, tables]
import malebolgia
import malebolgia / lockers

proc countWords[T](filename: string; results: Locker[CountTable[T]]) =
  for w in splitWhitespace(readFile(filename)):
    lock results as r:
      r.inc w

proc main[T]() = # test that all this works in a generic context
  var m = createMaster()
  var results = initLocker initCountTable[T]()

  m.awaitAll:
    m.spawn countWords("README.md", results)
    m.spawn countWords("malebolgia.nimble", results)

  unprotected results as r:
    r.sort()
    echo r

main[string]()
