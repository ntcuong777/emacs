/* Thread-aware I/O multiplexer for dual-thread UI model.

   IGC safety: event_loop_select runs on the Lisp thread and calls
   platform-specific select functions (mac_select, xg_select, etc.)
   which may trigger GC via igc_on_idle.  The select coordination with
   the GUI thread is safe because:

   - MPS suspends all registered threads during GC flips
   - The GUI thread is registered with MPS via igc_register_gui_thread()
     (lazily on first allocation from thread_ap)
   - The GUI thread has its own allocation points and C stack root
   - The GUI thread's C stack is scanned by MPS during flips (via the
     ambiguous stack root), preventing collection of Lisp_Object
     references held in local variables
   - On macOS, Mach thread_suspend() works regardless of thread state
     (semaphore wait, mutex lock, etc.), so cross-thread dispatch is
     safe during GC flips
   - The process_one_message finalization path parks the arena to
     prevent flips from suspending threads during finalizer execution

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

#ifndef EVENT_LOOP_H
#define EVENT_LOOP_H

#include <stdbool.h>
#include <sys/select.h>
#include <signal.h>

struct terminal;


/***********************************************************************
		      Thread-aware select

   Replaces pselect, thread_select, xg_select, ns_select, and
   mac_select.  Coordinates the GUI thread's event pump with the
   Emacs thread's I/O multiplexing.

   Must be called from the Emacs (Lisp) thread.
***********************************************************************/

/* Wait for I/O on FDSETs with TIMEOUT and SIGMASK, while
   simultaneously running the GUI event pump on the GUI thread.

   If TERMINAL is NULL or dual_thread_p is false, this falls back to
   thread_select(pselect, ...) directly.

   Returns:
     >0  number of ready file descriptors
      0  timeout expired
     -1  error (errno set); EINTR means GUI events are pending

   The caller should check detect_input_pending() after EINTR.  */
extern int event_loop_select (struct terminal *terminal,
			      int nfds,
			      fd_set *rfds, fd_set *wfds, fd_set *efds,
			      struct timespec *timeout,
			      sigset_t *sigmask);


/***********************************************************************
		      GUI thread event loop

   Runs the GUI thread's main event processing loop.
   Called from main() / the terminal startup code on the GUI thread.
   Does not return (blocks forever, processing work dispatched from
   the Emacs thread via sync_call_on_gui_thread etc.).
***********************************************************************/

/* Enter the GUI thread's event loop for TERMINAL.
   Only returns when the terminal is deleted or the process exits.
   Must be called on the GUI thread.  */
extern void event_loop_run_gui (struct terminal *terminal);

/* Process one work item on the GUI thread (used internally by
   event_loop_run_gui and by sync_call_on_emacs_thread to re-enter
   the GUI loop).  */
extern void event_loop_gui_process (struct terminal *terminal);


/***********************************************************************
		      Event loop initialization
***********************************************************************/

/* Initialize event loop state for TERMINAL.
   Called during terminal creation if dual_thread_p == true.  */
extern void event_loop_init (struct terminal *terminal);

/* Deinitialize event loop state for TERMINAL.  */
extern void event_loop_deinit (struct terminal *terminal);

/* Return the file descriptor that the Emacs thread should include in
   its pselect/select read set to be woken up by the GUI thread.  */
extern int event_loop_wakeup_fd (struct terminal *terminal);

/* Set or clear buffer/glyph-matrix access restrictions for the GUI
   thread.  Called when other Lisp threads may be running.  */
extern void event_loop_set_buffer_access_restricted
  (struct terminal *terminal, bool restricted);

#endif /* EVENT_LOOP_H */
