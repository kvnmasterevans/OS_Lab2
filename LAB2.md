# Lab 2: Lottery and Stride Schedulers — Change Log

This file tracks every change made to xv6 for CS 202 Lab 2. Update it
whenever you change lab2-related code, so the report can be written from it.

## Status

| Part | Item | Status |
|------|------|--------|
| Setup | Toolchain fixes for GCC 15 | Done |
| Part 1 | Per-process `tickets`, `ticks`, `pass` fields | Done |
| Part 1 | `sched_statistics()` syscall | Done |
| Part 1 | `sched_tickets(int)` syscall | Done |
| Part 1 | Tick counting on dispatch | Done, shared by all schedulers via `run_proc()` |
| Test | `user/lab2.c` test program | Done |
| Part 2 | Makefile `LAB2` switch (`-DRR` / `-DLOTTERY` / `-DSTRIDE`) | Done |
| Part 2 | `CPUS := 1` in Makefile | Done |
| Part 2 | Scheduler `#if` skeleton and `run_proc()` helper | Done |
| Part 2 | Lottery scheduler + provided `rand()` | Not started (falls back to round-robin) |
| Part 2 | Stride scheduler (K = 10000) | Done and tested |
| Part 3 | Experiments (8:4:2:1 and 1:1:1:1, 20–100 ticks, ≥5 runs) | Not started |
| Submit | Report PDF, demo video | Not started |

## Changes

### Setup: toolchain fixes (commit `ec23a70`)

Needed for newer compilers such as Ubuntu's GCC 15. They also work with
older toolchains such as GCC 13 on Ubuntu 24.04.

- **`Makefile`**: added `-march=rv64gc -mabi=lp64d` to `CFLAGS` and a new
  `ASFLAGS`. GCC 15 defaults to the RVA23 profile and emits instructions,
  such as `c.mul`, that QEMU's default `virt` CPU rejects. The symptom was a
  silent hang at boot with no "xv6 kernel is booting" message.
- **`user/usertests.c`**: changed `rwsbrk()` to `rwsbrk(char *s)` to match
  the other test functions. GCC 15's C23 default made the old declaration
  a type error.

Because of these two Makefile lines, the lab handout's "lines 72-73"
reference for inserting `LAB2 = RR` is now two lines lower.

### Part 1: process fields (commit `2f6037c`)

- **`kernel/proc.h`**: `struct proc` gains
  - `int tickets`: ticket count (lottery share and stride weight).
  - `int ticks`: number of times the process was scheduled to run.
  - `uint pass`: stride scheduler pass value.

  It also gains `MAX_TICKETS` (10000, the upper bound for `sched_tickets`)
  and `DEFAULT_TICKETS` (10000, the value every new process starts with).
- **`kernel/proc.c` `allocproc()`**: initializes `tickets = DEFAULT_TICKETS`,
  `ticks = 0`, `pass = 0`. Children do not inherit tickets from the parent.

### Part 1: system calls

| Syscall | Number | Behavior |
|---------|--------|----------|
| `int sched_statistics(void)` | 22 | Prints `PID(name): tickets: T, ticks: N` for every process that is not `UNUSED`. Returns 0. |
| `int sched_tickets(int n)` | 23 | Sets the caller's tickets to `n`, clamped to the range 1 to 10000. Returns 0. |

The lower clamp to 1 is our own choice; the handout only gives the
maximum. It keeps a process schedulable and prevents a divide-by-zero in
stride.

Files touched:

- **`kernel/syscall.h`**: `SYS_sched_statistics 22`, `SYS_sched_tickets 23`.
- **`kernel/syscall.c`**: `extern` declarations and syscall table entries.
- **`kernel/sysproc.c`**: `sys_sched_statistics()` and `sys_sched_tickets()`
  wrappers. The second reads its argument with `argint`.
- **`kernel/proc.c`**: `sched_statistics()` walks `proc[]`, taking each
  `p->lock` while reading it. `sched_tickets()` clamps the value and stores
  it under the caller's lock.
- **`kernel/defs.h`**: prototypes for both kernel functions.
- **`user/usys.pl`**: `entry("sched_statistics")`, `entry("sched_tickets")`.
- **`user/user.h`**: user-side prototypes.

### Part 1: tick counting

- **`kernel/proc.c` `scheduler()`**: `p->ticks++` right before
  `swtch()`, on the common dispatch path.

**Rule for Part 2:** keep exactly one `p->ticks++` on the dispatch
path of every scheduler variant, either after the `#if` selection logic
or once in each branch. Otherwise `sched_statistics` will be wrong for
that scheduler.

### Part 2: shared scheduler setup (commit `bec7e23`)

- **`Makefile`**: `LAB2 = RR` and `CFLAGS += -D$(LAB2)` after the
  `-fno-pie` block, as the handout specifies. `CPUS := 1`.
- **`kernel/proc.c` `run_proc(c, p)`**: the dispatch steps shared by
  every policy. It sets the process RUNNING, increments `p->ticks`, and
  switches to it. The caller must hold `p->lock` and `p` must be
  RUNNABLE. This keeps the tick count correct under every scheduler.
- **`kernel/proc.c` `scheduler()`**: `#if defined(LOTTERY)` /
  `#elif defined(STRIDE)` / `#else` round-robin. Each branch only picks
  a process and calls `run_proc()`. The LOTTERY branch is still the
  round-robin loop with a `TODO(lottery)` so LOTTERY builds boot.

### Part 2: stride scheduler (commit `46c9a41`)

Basic stride scheduling from Sec 2.1 of the paper, plus a join rule so
processes that start late do not monopolize the CPU.

- **`kernel/proc.h`**: `STRIDE1` (10000, the constant K), `int stride`
  (`STRIDE1 / tickets`), and `pass` widened from `uint` to `uint64`.
  The handout does not require 64 bits. We chose it so pass values
  cannot overflow, as the paper's appendix recommends.
- **`allocproc()`**: `stride = STRIDE1 / DEFAULT_TICKETS`, which is 1.
- **`scheduler()` STRIDE branch**:
  1. Scan `proc[]` for the RUNNABLE process with the smallest pass.
     Ties go to the lowest slot because the comparison is strict `<`.
  2. Lock it and check it is still RUNNABLE.
  3. Add its stride to its pass and call `run_proc()`.
- **`stride_min_pass(skip, &found)`**: returns the smallest pass among
  RUNNABLE and RUNNING processes other than `skip`. This serves as the
  current "virtual time". It holds only one process lock at a time.
- **Pass reset in `sched_tickets()`**: recomputes the stride. Under
  STRIDE it also sets the caller's pass to the virtual time plus its new
  stride. If no other process is active, the caller's own pass is used.
- **Pass reset in `fork()`**: under STRIDE the child's pass is the
  virtual time, which includes the running parent, plus the child's
  stride.

  This one is required, not optional. Without it a new child starts at
  pass 0. The child of a long-running parent then runs alone until it
  catches up with the parent's pass. `usertests -q` hung in
  `killstatus` because of this.

Integer strides round down: 30:20:10 gives 333 / 500 / 1000, and
19:1 gives 526 / 10000. 8:4:2:1 divides exactly.

### Test program

- **`user/lab2.c`**: the handout's test program, copied verbatim.
- **`Makefile`**: `$U/_lab2` added to `UPROGS`.

## Build and run

Run all commands from the repository root. Always run `make clean` when
switching schedulers, because the `-D` flag does not trigger a rebuild.

```sh
# Original round-robin scheduler
make clean; make qemu

# Lottery scheduler
make clean; make qemu LAB2=LOTTERY

# Stride scheduler
make clean; make qemu LAB2=STRIDE
```

Exit QEMU with `Ctrl-a` then `x`.

## Tests (inside the xv6 shell)

```sh
# Handout example: 3 processes, 30:20:10 tickets, 100 ticks.
# Ideal share of the last three lines: 1/2, 1/3, 1/6.
lab2 100 3 30 20 10

# Demo video case: 2 processes, 19:1 tickets. Ideal share: 95% / 5%.
lab2 100 2 19 1

# Clamp check for sched_tickets: 20000 becomes 10000 and 0 becomes 1.
lab2 50 2 20000 0

# Part 3 experiment 1 (8:4:2:1); repeat with 20, 40, 60, 80, 100.
lab2 20 4 8 4 2 1

# Part 3 experiment 2 (1:1:1:1); repeat with 20, 40, 60, 80, 100.
lab2 20 4 1 1 1 1
```

Only the child lines (the last N lines) matter. Each child's share is its
`ticks` divided by the sum of the children's `ticks`.

### Expected results

| Scheduler | `lab2 100 3 30 20 10` children |
|-----------|-------------------------------|
| Round-robin | About equal ticks, tickets ignored. Verified: 34 / 34 / 34. |
| Lottery | Roughly 1/2, 1/3, 1/6, with random variation. |
| Stride | 1/2, 1/3, 1/6. Verified: 50 / 33 / 17, identical across runs. |

Verified stride results for the other tests:

| Test | Child ticks |
|------|-------------|
| `lab2 100 2 19 1` | 95 / 5 |
| `lab2 100 4 8 4 2 1` | 53 / 27 / 13 / 7 |
| `lab2 100 4 1 1 1 1` | 25 / 25 / 25 / 25 |
| `lab2 20 4 8 4 2 1` | 10 / 5 / 3 / 2 |

The parent `lab2` process also shows about 100 ticks. That is expected:
`sleep()` wakes it on every timer tick to re-check the time.

### Regression check

```sh
usertests -q
```

This takes a few minutes. Under RR and STRIDE, every test passes except
`textwrite`. That failure comes from the toolchain, not the scheduler.
The newer linker puts user code and data in one writable segment (the
"RWX permissions" warning), so writing to address 0 does not fault.

### Non-interactive run (for scripts)

QEMU's console needs a pseudo-terminal, so a plain pipe shows no output.
Wrap it with `script`:

```sh
(sleep 8; echo "lab2 100 3 30 20 10"; sleep 12; printf '\001x') \
  | timeout 60 script -qfc "make qemu CPUS=1" /dev/null | tr -d '\r'
```
