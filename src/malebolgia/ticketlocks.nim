## Ticketlocks for Nim.
## A ticket lock is a fair lock, ideal for guaranteed worst case execution times (WCET).
## This implementation has the advantage that no `deinit` nor a destructor has to be
## run making it especially convenient to use.

import std / atomics

type
  TicketLock* = object
    nextTicket, nowServing: Atomic[int]

proc acquire*(L: var TicketLock) {.inline.} =
  let myTicket = L.nextTicket.fetchAdd(1, moRelaxed)
  while L.nowServing.load(moAcquire) != myTicket:
    cpuRelax()

proc release*(L: var TicketLock) {.inline.} =
  let myTicket = L.nowServing.load(moRelaxed)
  L.nowServing.store(myTicket + 1, moRelease)

proc initTicketLock*(): TicketLock = TicketLock()
