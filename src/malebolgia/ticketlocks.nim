## Ticketlocks for Nim.
## A ticket lock is a fair lock, ideal for guaranteed worst case execution times (WCET).
## This implementation has the advantage that no `deinit` nor a destructor has to be
## run making it especially convenient to use.

import std / atomics

type
  TicketLock* = object
    nextTicket, nowServing: Atomic[int]

# See https://mfukar.github.io/2017/09/08/ticketspinlock.html for the ideas used here.

proc acquire*(L: var TicketLock) {.inline.} =
  let myTicket = L.nextTicket.fetchAdd(1, moRelaxed)
  while true:
    let currentlyServing = L.nowServing.load(moAcquire)
    if currentlyServing == myTicket: break

    let previousTicket = myTicket - currentlyServing
    # assume the other CPU uses the lock for 30 cycles at least:
    var delaySlots = 30 * previousTicket
    while true:
      cpuRelax()
      dec delaySlots
      if delaySlots <= 0: break

proc release*(L: var TicketLock) {.inline.} =
  let myTicket = L.nowServing.load(moRelaxed)
  L.nowServing.store(myTicket + 1, moRelease)

proc initTicketLock*(): TicketLock = TicketLock()

template withLock*(a: TicketLock; body: untyped) =
  ## Acquires the given lock, executes the statements in body and
  ## releases the lock after the statements finished executing.
  acquire(a)
  {.gcsafe.}:
    try:
      body
    finally:
      release(a)

# ---------------------------------------------------------------------------
# Fair reader-writer spinlock
# ---------------------------------------------------------------------------
#
# WCET guarantee (O(1) critical section assumed):
#   acquireRead  waits for at most one writer epoch ahead of it in the queue,
#                plus O(K) reader registrations (K = threads/stripe, typically 1).
#   acquireWrite waits for its position in the ticket queue, then for at most
#                K readers (those already registered) to drain — both O(1).
#
# Protocol:
#   Readers and writers are served in strict FIFO order via the inner
#   TicketLock.  A reader acquires the ticket lock only long enough to
#   increment `readers` and release — so concurrent readers behind it in the
#   queue proceed immediately after.  A writer holds the ticket lock
#   exclusively and spins on `readers == 0` before entering its critical
#   section; no new reader can register while the writer holds the lock.
#
# No deinit/destructor needed (same as TicketLock).

type
  TicketRWLock* = object
    ## Fair reader-writer spinlock.  Readers run concurrently; a writer is
    ## exclusive.  Both are served in FIFO ticket order → O(1) WCET.
    ticket: TicketLock
    readers: Atomic[int]

proc acquireRead*(L: var TicketRWLock) {.inline.} =
  # Get our place in the FIFO queue, register, and leave quickly so readers
  # behind us can also register (and run concurrently with us).
  L.ticket.acquire()
  discard L.readers.fetchAdd(1, moRelaxed) # register before releasing
  L.ticket.release()

proc releaseRead*(L: var TicketRWLock) {.inline.} =
  discard L.readers.fetchSub(1, moRelease) # moRelease pairs with writer's moAcquire

proc acquireWrite*(L: var TicketRWLock) {.inline.} =
  # Hold the ticket lock for the entire writer critical section: no new
  # reader can register while we hold it.  Spin until readers that registered
  # before us (their fetchAdd happened before our acquire) have all exited.
  L.ticket.acquire()
  while L.readers.load(moAcquire) > 0: cpuRelax()

proc releaseWrite*(L: var TicketRWLock) {.inline.} =
  L.ticket.release()

proc initTicketRWLock*(): TicketRWLock = TicketRWLock()

template withReadLock*(L: var TicketRWLock; body: untyped) =
  acquireRead(L)
  {.gcsafe.}:
    try:
      body
    finally:
      releaseRead(L)

template withWriteLock*(L: var TicketRWLock; body: untyped) =
  acquireWrite(L)
  {.gcsafe.}:
    try:
      body
    finally:
      releaseWrite(L)
