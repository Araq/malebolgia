# malebolgia
Malebolgia creates new spawns. Experiments with thread pools and related APIs.

## Ideas / Goals

- Works well on embedded devices.
- Bounded memory consumption: Solves the "backpressure" problem as a side effect.
- Only support "structured" concurrency.

## Features

- Detach the notion of "wait for all tasks" from the notion of a "thread pool".
- Detects simple "read/write" and "write/write" conflicts.
- Builtin support for cancelation and timeouts.
