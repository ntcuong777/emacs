# USE_POLL: Replacing select(2) with poll(2) in Emacs

## Motivation

The traditional `select(2)` system call has a hard limit: it cannot monitor
file descriptors with values >= `FD_SETSIZE` (typically 1024 on macOS,
sometimes 256 on older systems). This limit is baked into the `fd_set` data
structure at compile time.

Emacs can exhaust this limit under real-world conditions:

- macOS CoreFoundation/Foundation libraries raise the process file descriptor
  limit on first use (e.g., `CFSocketGetTypeID`, `NSFileHandle`), causing new
  fds to be numbered above 1024.
- Heavy subprocess usage (LSP servers, git processes, compilation buffers,
  shell sessions) accumulates open pipes and sockets.
- `desktop.el` session restore reopens many buffers simultaneously, each
  potentially spawning subprocesses (e.g., for `vc-mode` in git directories).

When an fd >= `FD_SETSIZE` is passed to `select(2)`, the behavior is
**undefined** -- typically silent memory corruption or segfault in the
`FD_SET`/`FD_ISSET` macros, which index into a fixed-size bitmap.

`poll(2)` has no such limit. It takes an array of `struct pollfd` entries
with explicit fd values, so any valid file descriptor can be monitored.

## Design

### Build-time opt-in

The feature is gated behind `--with-poll` at configure time (default: off).

```
configure.ac:
  OPTION_DEFAULT_OFF([poll], ...)
  AC_CHECK_HEADERS([poll.h])
  AC_DEFINE([USE_POLL], 1, ...)
  AC_CHECK_FUNCS([ppoll])        # atomic signal-masked poll
```

When `USE_POLL` is defined, three things happen in `sysselect.h`:

1. `FD_SETSIZE` is redefined to 10240 (the effective limit).
2. `fd_set` is redefined to `emacs_fd_set` (a wider bitset struct).
3. `pselect` is redefined to `emacs_pselect` (the poll-based wrapper).

### Transparent substitution via macro redirection

The key design decision is **macro-level substitution**: all existing Emacs
code continues to use `fd_set`, `FD_SET`, `FD_CLR`, `FD_ISSET`, `FD_ZERO`,
`FD_SETSIZE`, and `pselect` -- these are silently redirected to the wider
types and poll-based implementation. No code outside of `sysselect.h` and
`process.c` needs to change.

```
sysselect.h (when USE_POLL is defined):

  #undef  FD_SETSIZE
  #define FD_SETSIZE 10240

  #define fd_set    emacs_fd_set      -- wider bitset
  #define pselect   emacs_pselect     -- poll-based wrapper
  #define FD_SET    ...               -- operate on emacs_fd_set
  #define FD_CLR    ...
  #define FD_ISSET  ...
  #define FD_ZERO   memset(...)
```

The `emacs_fd_set` type:

```c
typedef struct {
  EMACS_UINT bits[FD_SETSIZE / EMACS_UINT_WIDTH];  // 10240/64 = 160 words
} emacs_fd_set;                                      // 1280 bytes
```

### Poll wrapper implementation (process.c)

Four functions implement the bridge between fd_set semantics and poll(2):

```
fd_sets_to_pollfds(rset, wset, eset, nfds, pfds) -> poll_count
  Scans emacs_fd_set bitmaps up to nfds, populating a caller-supplied
  struct pollfd[] array with {fd, events, revents=0} entries.
  Maps: rset -> POLLIN, wset -> POLLOUT, eset -> POLLPRI.

pollfds_to_fd_sets(rset, wset, eset, pfds, poll_count) -> ready
  Reverse mapping: reads pfds[].revents and sets bits in rset/wset/eset.
  Maps POLLERR/POLLNVAL to both read and write sets (matching select
  semantics).  Maps POLLPRI to the exception set.
  Returns the total number of bits set across all output sets,
  matching pselect's return-value contract.

timespec_to_timeout(ts) -> milliseconds
  Converts pselect-style timespec to poll-style millisecond timeout.
  Clamps to INT_MAX to prevent overflow.

emacs_pselect(nfds, readfds, writefds, errorfds, timeout, sigmask)
  The main entry point. Signature matches pselect(2).
  Allocates a per-call pollfd buffer (stack for <= 128 fds, heap
  otherwise), converts fd_sets -> pollfds, calls poll/ppoll,
  converts back, and frees the heap buffer if used.
```

### Data flow

```
caller (process.c, nsterm.m, xgselect.c, ...)
  |
  v
pselect(nfds, rfds, wfds, efds, timeout, sigmask)
  |  [macro-redirected to emacs_pselect]
  v
emacs_pselect()
  |
  +-- allocate per-call pfds[] (stack or heap)
  |
  +-- fd_sets_to_pollfds()   -- emacs_fd_set -> struct pollfd[]
  |
  +-- ppoll() or poll()      -- actual system call
  |
  +-- pollfds_to_fd_sets()   -- struct pollfd[] -> emacs_fd_set
  |
  +-- free pfds[] if heap-allocated
  |
  v
caller reads rfds/wfds/efds as usual
```

### Call sites

All pselect/select call sites are transparently handled:

| Location | Context |
|----------|---------|
| `process.c:wait_reading_process_output` | Main I/O multiplexing loop via `thread_select(pselect, ...)` |
| `process.c:connect_network_socket` | Socket connect completion wait |
| `process.c` (no-subprocess path) | Simple wait on single fd |
| `nsterm.m:ns_select` | macOS Cocoa event loop via `thread_select(pselect, ...)` |
| `nsterm.m` (fd_select helper) | NS helper thread I/O wait |
| `xgselect.c:xg_select` | GLib/GTK event loop integration via `thread_select(pselect, ...)` |

### Thread safety

`emacs_pselect` uses a per-call `struct pollfd` buffer: a 128-entry stack
array for the common case, with heap fallback via `xnmalloc`/`xfree` for
larger fd counts. This makes it safe for concurrent calls from different
threads.

This matters on macOS NS builds, where:
- The main thread calls `emacs_pselect` via `thread_select(pselect, ...)`
  from `ns_select_1` (nsterm.m).
- The Cocoa `fd_handler` helper thread calls `pselect` (redirected to
  `emacs_pselect`) directly from its own run loop (nsterm.m:6642, 6676),
  without going through `thread_select` or holding the global lock.

An earlier version used a single global `pollfds[]` array, which would
allow these concurrent calls to corrupt each other's readiness data.

---

## Analysis of original patch bugs

### Bug 1: POLLERR/POLLNVAL silently dropped (CRITICAL -- likely segfault cause)

**Original code:**
```c
if (pollfds[i].revents & (POLLIN|POLLHUP))
    FD_SET (pollfds[i].fd, rset);
if (pollfds[i].revents & POLLOUT)
    FD_SET (pollfds[i].fd, wset);
```

**Problem:** When a file descriptor enters an error state (closed pipe,
invalid fd), `poll(2)` sets `POLLERR` or `POLLNVAL` in `revents` and returns
a positive value (indicating an event occurred). But the original code only
checked `POLLIN|POLLHUP` and `POLLOUT`, so error events were silently
discarded.

The caller (e.g., `wait_reading_process_output`) sees `pselect` return > 0
(something happened) but finds no fds set in either `rfds` or `wfds`. This
causes:

- **Infinite busy-loop**: The caller re-enters pselect immediately, poll
  returns the same error again, ad infinitum, burning CPU.
- **Stale state**: The errored fd is never cleaned up because the caller
  never discovers it is in an error state.
- **Segfault**: In some code paths, the caller assumes at least one fd is
  ready when pselect returns > 0, and dereferences or indexes based on that
  assumption.

This is the most likely cause of the startup segfault when opening a git
directory with `desktop.el` -- multiple subprocesses (git, vc-mode) are
spawning and dying rapidly; their pipe fds can enter error states between
the time they are registered and the next select/poll cycle.

**Fix:**
```c
short revents = pollfds[i].revents;
if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))
    FD_SET (pollfds[i].fd, rset);
if (revents & (POLLOUT | POLLERR | POLLNVAL))
    FD_SET (pollfds[i].fd, wset);
```

This matches `select(2)` semantics: errored fds appear in all applicable
sets, so the caller discovers the error on the next `read(2)` or `write(2)`.

### Bug 2: sigmask argument completely ignored (CRITICAL -- signal race)

**Original code:**
```c
/* The sigmask argument is not handled, since Emacs doesn't
   actually use it.  */
ret = poll (pollfds, poll_count, timespec_to_timeout (timeout));
```

**Problem:** The comment is wrong. While Emacs passes `NULL` for the sigmask
in most direct `pselect` calls, the `thread_select` infrastructure passes
the sigmask through to the underlying select function via `really_call_select`:

```c
// thread.c:really_call_select
sa->result = (sa->func)(sa->max_fds, sa->rfds, sa->wfds, sa->efds,
                        sa->timeout, sa->sigmask);
```

The whole point of `pselect(2)` over `select(2)` is atomic signal mask
manipulation: it atomically sets the signal mask, waits, and restores it.
This prevents the classic race condition where:

1. Process checks for pending signals (none)
2. SIGCHLD arrives (between check and sleep)
3. Process enters sleep (poll/select) and misses the signal

During Emacs startup with `desktop.el` restoring a git directory, many child
processes spawn and exit in rapid succession. Each exit delivers SIGCHLD.
Without atomic signal masking, SIGCHLD can be delivered during the window
between `fd_sets_to_pollfds` and `poll`, causing it to be lost. The dead
child process is never reaped, its fd is never cleaned up, and subsequent
reads on its pipe fd return errors that (combined with Bug 1) were silently
dropped.

**Fix:** Use `ppoll(2)` where available (Linux, recent FreeBSD/OpenBSD),
which provides the same atomic signal masking as `pselect(2)`:

```c
#ifdef HAVE_PPOLL
ret = ppoll (pollfds, poll_count, timeout, sigmask);
#else
sigset_t origmask;
if (sigmask)
    pthread_sigmask (SIG_SETMASK, sigmask, &origmask);
ret = poll (pollfds, poll_count, timespec_to_timeout (timeout));
if (sigmask)
    pthread_sigmask (SIG_SETMASK, &origmask, NULL);
#endif
```

On macOS, `ppoll` is not available, so we fall back to a
`pthread_sigmask`/`poll`/`pthread_sigmask` sandwich. There is a small
race window between `pthread_sigmask` and `poll`, but this is strictly
better than ignoring the sigmask entirely and matches what other programs
do as a `pselect` fallback.

### Bug 3: Integer overflow in timespec_to_timeout

**Original code:**
```c
return (ts->tv_sec * 1000 + ts->tv_nsec / 1000000);
```

**Problem:** `ts->tv_sec` is `time_t` (typically `long`, 64-bit). The return
type is `int` (32-bit). When `tv_sec` exceeds ~2,147,483 seconds (~24.8
days), `tv_sec * 1000` overflows `int` range, producing a negative value.
A negative timeout argument to `poll(2)` means "wait forever" (-1) on most
systems, but other negative values produce undefined behavior or immediate
return.

This is unlikely to cause the startup crash but could manifest as hangs or
unexpected timeouts in long-running Emacs sessions.

**Fix:**
```c
if (ts->tv_sec > (long)(INT_MAX / 1000))
    return INT_MAX;
return (int)(ts->tv_sec * 1000 + ts->tv_nsec / 1000000);
```

### Bug 4: revents not cleared before poll()

**Original code:**
```c
pollfds[poll_idx].fd = i;
pollfds[poll_idx].events = flag;
// revents not set -- retains value from previous poll() call
```

**Problem:** The `pollfds[]` array is global and persistent. While POSIX
specifies that `poll(2)` sets `revents` for each entry, not all
implementations are guaranteed to clear bits that are not set. More
importantly, if a previous call populated more entries than the current call,
those stale entries persist in the array. Although we only pass `poll_count`
entries to `poll()` and only read that many back, defensively clearing
`revents` prevents any possibility of reading stale flags.

**Fix:**
```c
pollfds[poll_idx].revents = 0;
```

### Bug 5: Non-exclusive #ifdef structure in sysselect.h

**Original code:**
```c
#ifdef FD_SET
  // system fd_set path (FD_SETSIZE bumped to 10240)
#endif
#ifdef USE_POLL
  // poll path (FD_SETSIZE also bumped to 10240)
  // undefs and redefines FD_SET, FD_CLR, etc.
#endif
```

**Problem:** Both blocks execute when `USE_POLL` is defined and the system
provides `FD_SET` (the common case). The first block keeps the system's
macros; the second undefs and redefines them. While functionally correct (the
second block's undefs override the first), it is fragile:

- The first block's `#define FD_SETSIZE 10240` (hard bump) attempts to
  enlarge the system `fd_set`, but this cannot work because `<sys/select.h>`
  was already included at the top of the file, compiling `fd_set` at the
  system's default size (1024 on macOS). The 10240 value takes effect only
  if the system does not define `FD_SETSIZE` at all (rare).
- The `typedef int fd_set` in the `#else /* no FD_SET */` branch conflicts
  with the subsequent `#define fd_set emacs_fd_set` -- the typedef'd `int`
  remains visible alongside the macro, though the macro shadows it for new
  uses.

**Fix:** Use a clean mutually exclusive structure:

```c
#ifndef USE_POLL
  // standard select path (system fd_set, system FD_SETSIZE)
#else
  // poll path (emacs_fd_set, FD_SETSIZE=10240)
#endif
```

### Bug 6: Deprecated header <sys/poll.h>

**Original code:**
```c
#include <sys/poll.h>
```

**Problem:** POSIX specifies `<poll.h>` as the standard header. The
`<sys/poll.h>` path is a legacy compatibility alias that some systems do not
provide (notably some musl-based Linux distributions and certain BSDs).

**Fix:** Use `<poll.h>` in both `syspoll.h` and the `configure.ac` check.

### Bug 7: Global pollfds[] array not thread-safe on NS builds

**Original code:**
```c
static struct pollfd pollfds[FD_SETSIZE];
// ... used directly in fd_sets_to_pollfds and emacs_pselect
```

**Problem:** On macOS NS builds, two threads can call `pselect` (redirected
to `emacs_pselect`) concurrently:

- The main thread, via `thread_select(pselect, ...)` from `ns_select_1`.
- The Cocoa `fd_handler` helper thread, which calls `pselect` directly at
  `nsterm.m:6642` and `nsterm.m:6676` without going through `thread_select`
  or holding the global lock.

Both calls write to the same global `pollfds[]` array, so one can corrupt
the other's event data, leading to incorrect readiness results, missed I/O
events, or crashes.

**Fix:** Replace the global array with a per-call buffer. Use a 128-entry
stack array for the common case (128 * 8 = 1KB, well within stack limits)
and fall back to `xnmalloc`/`xfree` for larger fd counts:

```c
struct pollfd stack_pfds[128];
struct pollfd *pfds = stack_pfds;
bool heap = false;
if (nfds > 128)
  {
    pfds = xnmalloc (nfds, sizeof *pfds);
    heap = true;
  }
// ... use pfds ...
if (heap) xfree (pfds);
```

### Bug 8: errorfds (exception set) silently ignored

**Original code:**
```c
int emacs_pselect (int nfds, emacs_fd_set *readfds, emacs_fd_set *writefds,
                   emacs_fd_set *errorfds, ...)
{
  // errorfds accepted but never read, translated, or written back
  poll_count = fd_sets_to_pollfds (readfds, writefds, nfds);
  ...
}
```

**Problem:** The `pselect(2)` contract includes a third fd_set for
exceptional conditions (out-of-band data). The original code accepted
`errorfds` in the signature but completely ignored it: never scanned it for
set bits, never mapped them to `POLLPRI` events, and never wrote results
back. While no current Emacs caller passes a non-NULL `errorfds`, this
breaks the pselect contract and would silently misbehave if any caller ever
started using it.

Additionally, the return value was the raw `poll()` return (number of pollfd
entries with events), not the pselect-compatible count of bits set across all
output fd_sets. These differ when a single fd has both read and write events.

**Fix:** Full errorfds support:
- `fd_sets_to_pollfds`: map errorfds bits to `POLLPRI` in `events`.
- `pollfds_to_fd_sets`: map `POLLPRI` in `revents` to errorfds bits;
  return the total number of bits set across all three output sets.
- `emacs_pselect`: zero errorfds on error/timeout; return the bit count
  from `pollfds_to_fd_sets` instead of the raw poll return value.

---

## Portability

| Platform | poll(2) | ppoll(2) | Notes |
|----------|---------|----------|-------|
| Linux (glibc) | Yes | Yes (since 2.6.16) | Best path: ppoll for atomic sigmask |
| Linux (musl) | Yes | Yes | Same as glibc |
| macOS 10.3+ | Yes | No | Falls back to pthread_sigmask bracket |
| FreeBSD 11+ | Yes | Yes | ppoll available |
| OpenBSD 5.2+ | Yes | Yes | ppoll available |
| NetBSD 10+ | Yes | Yes | ppoll available |
| Windows (MSYS2) | N/A | N/A | USE_POLL not applicable; uses w32.h select |
| MS-DOS | N/A | N/A | Uses sys_select |
| Android | Yes | Yes | ppoll available via Bionic |

The `configure.ac` checks ensure correct behavior:
- `AC_CHECK_HEADERS([poll.h])` gates the entire feature.
- `AC_CHECK_FUNCS([ppoll])` detects the atomic variant.
- Both the `ppoll` path and the `pthread_sigmask` fallback compile and
  work correctly on all supported Unix-like platforms.

## Compatibility with IGC (MPS garbage collector)

The patch is fully compatible with the IGC/MPS branch (`feature/igc3`).

### GC-visible data structures

The only GC-visible static array affected is `chan_process[FD_SETSIZE]`
(an array of `Lisp_Object`). Under `USE_POLL`, `FD_SETSIZE` becomes 10240,
so this array grows from 1024 to 10240 entries. The IGC root registration
at the end of `init_process_emacs` uses `ARRAYELTS`:

```c
#ifdef HAVE_MPS
  igc_root_create_exact (chan_process, chan_process + ARRAYELTS (chan_process));
#endif
```

`ARRAYELTS` computes the size from `sizeof(array) / sizeof(array[0])`, so
it automatically picks up the larger size. No change needed.

### Coding system allocations

`proc_decode_coding_system` and `proc_encode_coding_system` are arrays of
pointers, allocated per-fd via `igc_xzalloc_ambig` under `HAVE_MPS` (at
lines ~7638, ~8543, ~8563 in process.c). These arrays grow to 10240 slots
but the allocation logic is unchanged -- each slot is still allocated
individually when a process is created. The pointers are traced ambiguously
by IGC, which works regardless of array size.

### New data introduced by the patch

| Data | Type | GC-visible? |
|------|------|-------------|
| `pollfds[FD_SETSIZE]` | `struct pollfd[]` (static) | No -- contains only C ints/shorts |
| `emacs_fd_set` locals | Stack-allocated bitsets | No -- contains only `EMACS_UINT` words |
| Conversion functions | Pure C computation | No Lisp objects touched |

None of the poll bridge code (`fd_sets_to_pollfds`, `pollfds_to_fd_sets`,
`timespec_to_timeout`, `emacs_pselect`) allocates, accesses, or stores
`Lisp_Object` values. No new IGC roots or ambiguous references are
introduced.

### `fd_callback_info` array

This array also grows to 10240 entries. It contains function pointers, void
data pointers, flags, and thread state pointers -- no `Lisp_Object` fields.
IGC does not scan it.

### Memory overhead

With `USE_POLL`, the enlarged static arrays increase BSS usage:

| Array | Entry size | Old (1024) | New (10240) | Delta |
|-------|-----------|------------|-------------|-------|
| `chan_process` | 8B (Lisp_Object) | 8KB | 80KB | +72KB |
| `fd_callback_info` | ~40B | 40KB | 400KB | +360KB |
| `pollfds` | 8B (struct pollfd) | -- | 80KB | +80KB |
| `proc_buffered_char` | 4B (int) | 4KB | 40KB | +36KB |
| `proc_decode_coding_system` | 8B (pointer) | 8KB | 80KB | +72KB |
| `proc_encode_coding_system` | 8B (pointer) | 8KB | 80KB | +72KB |
| `datagram_address` | ~16B | 16KB | 160KB | +144KB |
| **Total** | | **~84KB** | **~920KB** | **~836KB** |

The ~836KB increase is in BSS (zero-initialized, not backed by the
binary). For IGC specifically, the exact root scan of `chan_process` will
iterate 10240 entries instead of 1024, but most slots are `Qnil` and the
scan cost is negligible compared to a full GC cycle.

## Files changed

| File | Change |
|------|--------|
| `configure.ac` | Add `--with-poll` option, check for `poll.h` and `ppoll` |
| `src/sysselect.h` | Restructure to `#ifndef USE_POLL / #else`; define `emacs_fd_set`, redirect macros |
| `src/syspoll.h` | New file: declarations for poll bridge functions |
| `src/process.c` | Implement `fd_sets_to_pollfds`, `pollfds_to_fd_sets`, `timespec_to_timeout`, `emacs_pselect` |
| `src/nsterm.m` | Update comment (FD_SETSIZE limit explanation) |

## Usage

```sh
# Build with poll support
./configure --with-poll [other options]
make

# Verify at configure time
grep 'Does Emacs use.*poll' config.log
# Or check the configure summary output:
#   Does Emacs use 'poll'?   yes
```

## Testing

To test the fix, launch Emacs built with `--with-poll` in a scenario that
exercises heavy subprocess creation:

1. Open a large git repository.
2. Enable `desktop-save-mode` with many buffers including `vc-mode` backed
   buffers.
3. Save the session, quit, and restart.
4. During restart, `desktop.el` will reopen all buffers, triggering vc-mode
   to spawn git processes for each buffer.

Previously this would segfault during startup. The fix should allow Emacs to
start cleanly and handle all subprocess I/O without crashes.

Additional stress tests:
- Open 50+ shell buffers simultaneously.
- Run `M-x compile` with a command that produces heavy output while other
  subprocesses are active.
- Kill subprocesses while pselect is waiting (tests POLLERR/POLLHUP
  handling).
