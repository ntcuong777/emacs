/* Cross-thread synchronization primitives for dual-thread UI model.

   IGC/MPS thread safety:

   Both the GUI thread and the Lisp thread are registered with MPS:
   - Lisp thread: registered via add_main_thread() during init
     (mps_thread_reg called from emacs_main on the Lisp thread).
   - GUI thread: registered lazily via igc_register_gui_thread() on
     first allocation from the GUI thread (igc.c:thread_ap).

   Each thread has its own:
   - MPS thread handle (mps_thr_t, from mps_thread_reg)
   - Full set of allocation points (dflt_ap, leaf_ap, weak_aps, etc.)
   - Ambiguous C stack root (mps_root_create_thread_scanned)

   This means:
   - MPS can scan the GUI thread's C stack for Lisp_Object references
     during GC flips, preventing premature collection of objects that
     the GUI thread holds in local variables (e.g., between Fcons and
     kbd_buffer_store_event).
   - MPS suspends the GUI thread during flips (like any registered
     thread).  On macOS, Mach thread_suspend() works regardless of
     thread state (semaphore wait, mutex lock, etc.), so cross-thread
     dispatch is safe.
   - Each thread allocates from its OWN allocation points.  The arena
     lock internally synchronizes access.

   Safety rules:
   1. GUI thread allocates GC memory through its own allocation points
      (gui_gc_info in igc.c), lazily registered on first allocation.
   2. GUI thread must access Lisp data through sync_call_on_lisp_thread
      when not holding the global lock.
   3. GUI thread must never call igc_park_arena() -- the arena must be
      parked only from the Lisp thread which has the proper specpdl
      context for the unwind protect.
   4. During GC flips, MPS suspends ALL registered threads (both GUI
      and Lisp).  On macOS, Mach thread_suspend is safe regardless of
      thread state.  On Linux (future), signal-based suspension works
      on threads blocked on semaphores.

   Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

#ifndef SYNC_H
#define SYNC_H

#include <stdbool.h>

struct terminal;

/* A callback function for cross-thread dispatch.
   FN (DATA) is called on the target thread.  */
typedef void (*sync_block_fn) (void *data);


/***********************************************************************
		       Thread identity
***********************************************************************/

/* Return true if the current thread is the GUI thread for TERMINAL.
   If TERMINAL is NULL, return true only if the current thread is the
   GUI thread of any terminal.  */
extern bool gui_thread_p (const struct terminal *terminal);

/* Abort if the current thread is not the GUI thread for TERMINAL.  */
extern void gui_assert_thread (const struct terminal *terminal);

/* Return true if the current thread is the Emacs (Lisp) thread.  */
extern bool emacs_thread_p (const struct terminal *terminal);

/* Abort if the current thread is not the Emacs (Lisp) thread.  */
extern void emacs_assert_thread (const struct terminal *terminal);


/***********************************************************************
		    Per-terminal initialization
***********************************************************************/

/* Initialize the synchronization layer for TERMINAL.
   Must be called before any other sync functions with this terminal.
   Called from terminal init (e.g., mac_create_terminal).  */
extern void sync_init_terminal (struct terminal *terminal);

/* Deinitialize the synchronization layer for TERMINAL.  */
extern void sync_deinit_terminal (struct terminal *terminal);


/***********************************************************************
		   Cross-thread dispatch primitives

   These are the core communication primitives between the GUI thread
   and the Emacs (Lisp) thread.  They abstract the patterns used by
   the emacs-mac port: mac_within_gui, mac_within_lisp, and the
   deferred variants.

   Each terminal has its own sync state (queues, semaphores) created
   by sync_init_terminal.
***********************************************************************/

/* Call FN(DATA) on the GUI thread of TERMINAL synchronously.
   If already on the GUI thread, call FN directly.
   Blocks the calling thread until FN completes on the GUI thread.  */
extern void sync_call_on_gui_thread (struct terminal *terminal,
				     sync_block_fn fn, void *data);

/* Enqueue FN(DATA) for execution on the GUI thread of TERMINAL.
   Returns immediately without waiting.  FN will be executed on the
   GUI thread at the next opportunity.
   The caller is responsible for ensuring DATA lives until called.  */
extern void sync_defer_to_gui_thread (struct terminal *terminal,
				      sync_block_fn fn, void *data);

/* Call FN(DATA) on the Emacs (Lisp) thread synchronously.
   Used from GUI callbacks to evaluate Lisp code.
   Blocks the GUI thread until FN completes on the Emacs thread.  */
extern void sync_call_on_emacs_thread (struct terminal *terminal,
				       sync_block_fn fn, void *data);

/* Enqueue FN(DATA) for execution on the Emacs thread of TERMINAL.
   Returns immediately.  FN will execute at the next sync point in
   the Emacs thread (e.g., after sync_call_on_gui_thread completes).  */
extern void sync_defer_to_emacs_thread (struct terminal *terminal,
					sync_block_fn fn, void *data);

/* Call FN(DATA) on the GUI thread, but allow the GUI thread to
   recursively call sync_call_on_emacs_thread for inner evaluation.
   This corresponds to the mac_within_gui_allowing_inner_lisp pattern
   used for modal dialogs and menu tracking.  */
extern void sync_call_on_gui_thread_allowing_inner_lisp
  (struct terminal *terminal, sync_block_fn fn, void *data);


/***********************************************************************
		     Thread-safe block queues

   Abstract over NSMutableArray (macOS) / linked list with mutex
   (POSIX) / SLIST (Windows).
***********************************************************************/

typedef struct sync_block_queue sync_block_queue;

/* Create a new block queue.  Returns NULL on failure.  */
extern sync_block_queue *sync_block_queue_create (void);

/* Destroy a block queue and free all resources.
   Must be empty.  */
extern void sync_block_queue_destroy (sync_block_queue *q);

/* Push FN(DATA) onto the queue.  Thread-safe.  */
extern void sync_block_queue_push (sync_block_queue *q,
				   sync_block_fn fn, void *data);

/* Pop the frontmost entry.  Thread-safe.
   Returns true if an entry was popped; false if queue was empty.
   If true, *FN and *DATA are set.  */
extern bool sync_block_queue_pop (sync_block_queue *q,
				  sync_block_fn *fn, void **data);

/* Return the number of entries in the queue.  */
extern ptrdiff_t sync_block_queue_count (const sync_block_queue *q);


/***********************************************************************
		     Bidirectional semaphore pairs

   Replaces the dispatch_semaphore_t pair (mac_gui_semaphore /
   mac_lisp_semaphore) used in the emacs-mac port.
***********************************************************************/

typedef struct sync_sem_pair sync_sem_pair;

/* Create a new semaphore pair.  Index 0 is for waking the GUI thread,
   index 1 for waking the Lisp thread.  Returns NULL on failure.  */
extern sync_sem_pair *sync_sem_pair_create (void);

/* Destroy a semaphore pair.  No threads should be waiting.  */
extern void sync_sem_pair_destroy (sync_sem_pair *sp);

/* Wait on semaphore INDEX (0 or 1).  Blocks until signal.  */
extern void sync_sem_pair_wait (sync_sem_pair *sp, int index);

/* Signal semaphore INDEX (0 or 1).  Wakes one waiter.  */
extern void sync_sem_pair_signal (sync_sem_pair *sp, int index);


/***********************************************************************
		       Event-loop wakeup fd

   Replaces the mac_select_fds[] socketpair + dispatch_source pattern.
   Provides a file descriptor that can be added to the pselect/select
   fd set to break out of blocking waits when work arrives from the
   GUI thread.
***********************************************************************/

typedef struct sync_wakeup sync_wakeup;

/* Create a wakeup object.  Returns NULL on failure.  */
extern sync_wakeup *sync_wakeup_create (void);

/* Destroy a wakeup object.  */
extern void sync_wakeup_destroy (sync_wakeup *w);

/* Get the file descriptor to include in the read fd set for select.
   Writing to the wakeup causes this fd to become readable.  */
extern int sync_wakeup_fd (const sync_wakeup *w);

/* Wake up any thread blocked in select on this wakeup's fd.
   Thread-safe; can be called from signal handlers.  */
extern void sync_wakeup_signal (sync_wakeup *w);

/* Clear the wakeup state.  Call after select returns with this fd
   set.  */
extern void sync_wakeup_clear (sync_wakeup *w);

/* Get the file descriptor used to send wakeup signals.
   This is the "write end" for the Emacs -> GUI thread direction.
   If the select fd set includes this fd, the GUI thread can interrupt
   the Lisp thread's select.  */
extern int sync_wakeup_signal_fd (const sync_wakeup *w);


/***********************************************************************
		   Internal dispatch helpers

   Used by event-loop.c to process work items on the GUI thread.
***********************************************************************/

/* Process one GUI work item.  Dequeues from the GUI thread's work
   queue, executes fn(data), then signals completion to the Emacs
   thread.  Returns true if more work is pending.  */
extern bool sync_gui_process_one (struct terminal *terminal);

/* Accessors for internal sync state (used by event-loop.c).  */

/* Return the wakeup object for TERMINAL's sync state.  */
extern struct sync_wakeup *sync_get_wakeup (struct terminal *);

/* Return the semaphore pair for TERMINAL's sync state.  */
extern struct sync_sem_pair *sync_get_sem_pair (struct terminal *);

/* Block queue accessors for event-loop integration.  */
extern struct sync_block_queue *sync_get_gui_queue (struct terminal *);
extern struct sync_block_queue *sync_get_lisp_queue (struct terminal *);

/* Set/clear the buffer access restriction flag.  */
extern void sync_set_buffer_access_restricted (struct terminal *, bool);

/* Check if buffer access is currently restricted.  */
extern bool sync_buffer_access_restricted_p (struct terminal *);

/* Try to acquire or release the GIL from the GUI thread.
   These wrap gui_try_acquire_global_lock / gui_release_global_lock
   with dual-thread terminal awareness.  */
extern int sync_try_acquire_global_lock (struct terminal *);
extern int sync_release_global_lock (struct terminal *);

#endif /* SYNC_H */
