# (c) 2023 Andreas Rumpf

import malebolgia

template `@!`[T](data: openArray[T]; i: int): untyped =
  cast[ptr UncheckedArray[T]](addr data[i])

template parApply*[T](data: var openArray[T]; bulkSize: int; op: untyped) =
  ##[ Applies `op` on every element of `data`, `op(data[i])` in parallel.
  `bulkSize` specifies how many elements are processed sequentially
  and not in parallel because sending a task to a different thread
  is expensive. `bulkSize` should probably be larger than you think but
  it depends on how expensive the operation `op` is.]##
  proc worker(a: ptr UncheckedArray[T]; until: int) =
    for i in 0..<until: op a[i]

  var m = createMaster()
  m.awaitAll:
    var i = 0
    while i+bulkSize <= data.len:
      m.spawn worker(data@!i, bulkSize)
      i += bulkSize
    if i < data.len:
      m.spawn worker(data@!i, data.len-i)

template parMap*[T](data: openArray[T]; bulkSize: int; op: untyped): untyped =
  ##[ Applies `op` on every element of `data`, `op(data[i])` in parallel.
  Produces a new `seq` of `typeof(op(data[i]))`.
  `bulkSize` specifies how many elements are processed sequentially
  and not in parallel because sending a task to a different thread
  is expensive. `bulkSize` should probably be larger than you think but
  it depends on how expensive the operation `op` is.]##
  proc worker[Tin, Tout](a: ptr UncheckedArray[Tin];
                         dest: ptr UncheckedArray[Tout]; until: int) =
    for i in 0..<until: dest[i] = op(a[i])

  var m = createMaster()
  var result = newSeq[typeof(op(data[0]))](data.len)
  m.awaitAll:
    var i = 0
    while i+bulkSize <= data.len:
      m.spawn worker(data@!i, result@!i, bulkSize)
      i += bulkSize
    if i < data.len:
      m.spawn worker(data@!i, result@!i, data.len-i)
  result

template parReduce*[T](data: openArray[T]; bulkSize: int;
                       op: untyped): untyped =
  ##[ Computes in parallel:

  ```nim

    result = default(T)
    for i in 0..<data.len:
      op(result, a[i])

  ```

  `bulkSize` specifies how many elements are processed sequentially
  and not in parallel because sending a task to a different thread
  is expensive. `bulkSize` should probably be larger than you think but
  it depends on how expensive the operation `op` is.]##
  proc reduce[Tx](a: ptr UncheckedArray[Tx]; until: int): Tx =
    result = default(Tx)
    for i in 0..<until:
      op(result, a[i])

  var m = createMaster()
  var res = newSeq[T](data.len div bulkSize + 1)
  var r = 0
  m.awaitAll:
    var i = 0
    while i+bulkSize <= data.len:
      m.spawn reduce(data@!i, bulkSize) -> res[r]
      r += 1
      i += bulkSize
    if i < data.len:
      m.spawn reduce(data@!i, data.len-i) -> res[r]
      r += 1
  reduce(res@!0, r)


template parFind*[T](data: openArray[T]; bulkSize: int;
                     predicate: untyped): int =
  ##[ Computes in parallel:

  ```nim

    for i in 0..<data.len:
      if predicate(a[i]): return i
    return -1

  ```

  In words: It finds the minimum index for which `predicate` returns true.

  `bulkSize` specifies how many elements are processed sequentially
  and not in parallel because sending a task to a different thread
  is expensive. `bulkSize` should probably be larger than you think but
  it depends on how expensive the operation `op` is.]##
  proc linearFind[Tx](a: ptr UncheckedArray[Tx]; until, offset: int): int =
    for i in 0..<until:
      if predicate(a[i]): return i + offset
    return -1

  var m = createMaster()
  var res = newSeq[int](data.len div bulkSize + 1)
  var r = 0
  m.awaitAll:
    var i = 0
    while i+bulkSize <= data.len:
      m.spawn linearFind(data@!i, bulkSize, i) -> res[r]
      r += 1
      i += bulkSize
    if i < data.len:
      m.spawn linearFind(data@!i, data.len-i, i) -> res[r]
      r += 1
  var result = -1
  for i in 0..<r:
    if res[i] >= 0:
      result = res[i]
      break
  result
