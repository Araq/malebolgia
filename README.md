# malebolgia

   "The master told me what I had to do. He speaks to me and I know his name.
   He calls himself Malebolgia."

![](assets/malebolgia.png)

Malebolgia creates new spawns.

It is a powerful library in Nim that simplifies the implementation of
concurrent and parallel programming. It provides a straightforward approach to
expressing parallelism using the `spawn` construct and ensures synchronization
using barriers.


## Ideas / Goals

- Works well on embedded devices.
- Bounded memory consumption: Solves the "backpressure" problem as a side effect.
- Only support "structured" concurrency.

## Features

- Detach the notion of "wait for all tasks" from the notion of a "thread pool".
- Detects simple "read/write" and "write/write" conflicts.
- Builtin support for cancelation and timeouts.
- **Small**: Less than 300 lines of Nim code, no dependencies.
- Low energy consumption.
- **Fast**: Wins some benchmarks (crawler; DFS), shows acceptable performance for others (fib).


## Example

This program demonstrates the parallel execution of the depth-first search algorithm
using Malebolgia. By utilizing the `spawn` and `awaitAll` features, the program can
efficiently distribute the workload across multiple threads, enabling faster computation:


```nim

import malebolgia

proc dfs(depth, breadth: int): int {.gcsafe.} =
  if depth == 0: return 1

  # The seq where we collect the results of the subtasks:
  var sums = newSeq[int](breadth)

  # Create a Master object for task coordination:
  var m = createMaster()

  # Synchronize all spawned tasks using an AwaitAll block:
  m.awaitAll:
    for i in 0 ..< breadth:
      # Spawn subtasks recursively, store the result in `sums[i]`:
      m.spawn dfs(depth - 1, breadth) -> sums[i]

  result = 0
  for i in 0 ..< breadth:
    result += sums[i] # No `sync(sums[i])` required

let answer = dfs(8, 8)
echo answer

```

Notice the absence of a `FlowVar[T]` concept. Malebolgia does not offer
FlowVars because they are not required. Instead the barrier within `awaitAll`
synchronizes.

Compile this with `nim c -d:ThreadPoolSize=8 -d:FixedChanSize=16 dfs.nim`.


## Tuning

There are two parameters that influence the efficiency of Malebolgia:

1. `ThreadPoolSize`: Usually this should be the number of CPU cores, but for IO bound programs it can be much higher.
2. `FixedChanSize`: The fixed size of the communication channel(s). The default value is usually good enough.


## Exception handling

If a `spawned` task raises an exception, the master object notices and rethrows the exception after
`awaitAll`. If multiple tasks raise an exception only the first exception is kept and rethrown.


## Cancelation

Cancelation is available by calling `cancel` on the `master` object:

```nim

import malebolgia

proc foo = echo "foo"
proc bar(s: string) = echo "bar ", s

var m = createMaster()
m.awaitAll:
  m.spawn foo()
  for i in 0..<1000:
    m.spawn bar($i)
    if i == 300:
      # cancel after 300 iterations:
      m.cancel()

```


## Timeouts

`createMaster` supports an optional `timeout` parameter. The timeout covers
all created tasks that belong to the created master. Long running tasks
can query `master.cancelled` to see if they should stop.

```nim

import std / times
import malebolgia

proc bar(s: string) = echo "bar ", s

var m = createMaster(initDuration(milliseconds=500))
m.awaitAll:
  for i in 0..<1000:
    m.spawn bar($i)
  if not m.cancelled:
    # if not cancelled, run even more:
    for i in 1000..<2000:
      m.spawn bar($i)

```

## MasterHandle

A `Master` object cannot be passed to subroutines, but
a `MasterHandle` can be passed to subroutines. In order to create a `MasterHandle` 
use the `getHandle` proc:

```nim
import malebolgia

proc g(m: MasterHandle; i: int) {.gcsafe.} =
  if i < 800:
    echo "BEGIN G"
    m.spawn g(m, i+1)
    echo "END G"

proc main =
  var m = createMaster()
  m.awaitAll:
    m.spawn g(getHandle(m), 0)

main()

```

A `MasterHandle` does not support the `awaitAll` operation but it can `spawn`
new tasks and supports cancelation. Thus a `MasterHandle` object cannot be used
to break the structured concurrency abstraction.
