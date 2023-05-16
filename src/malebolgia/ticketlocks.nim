## Ticketlocks for Nim.
## A ticket lock is a fair lock, ideal for guaranteed worst case execution times (WCET)
## assuming that the number of threads is a constant which is true for Malebogia.

import std / atomics

type
  TicketLock* = object
    nextTicket, nowServing: Atomic[int]

proc acquire*(L: var TicketLock) {.inline.} =
  let myTicket = L.nextTicket.fetchAdd(1, moRelaxed)
  while L.nowServing.load(moAcquire) != myTicket:
    discard

proc release*(L: var TicketLock) {.inline.} =
  let myTicket = L.nowServing.load(moRelaxed)
  L.nowServing.store(myTicket + 1, moRelease)


