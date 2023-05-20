
# Handle support:

type
  MasterHandle* = object ## Handles to the master can be passed around as proc parameters.
                         ## A handle supports the `spawn` operation.
                         ## A handle does **not** support the `awaitAll` operation!
    x: ptr Master # Private field so that we can add more error checking in the future.

proc getHandle*(m: var Master): MasterHandle {.inline.} =
  ## Handles to the master are restricted
  result = MasterHandle(x: addr(m))

proc cancelled*(m: MasterHandle): bool {.inline.} =
  ## Query if the `master` object requested cancelation.
  cancelled(m.x[])

proc cancel*(m: MasterHandle) {.inline.} =
  ## Cancel all tasks belonging to `m`.
  cancel(m.x[])

template spawn*(m: MasterHandle; b: untyped) =
  ## A MasterHandle is allowed to spawn new tasks.
  spawn(m.x[], b)
