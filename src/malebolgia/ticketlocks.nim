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
