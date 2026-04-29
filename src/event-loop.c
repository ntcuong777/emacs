/* Thread-aware I/O multiplexer for dual-thread UI model.
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

#include <config.h>
#include <stddef.h>
#include <errno.h>
#include <sys/select.h>

#include "lisp.h"
#include "termhooks.h"
#include "thread.h"
#include "systhread.h"
#include "sync.h"
#include "event-loop.h"

/* Forward declarations.  */
static int do_fallback_select (struct terminal *terminal,
			       int nfds, fd_set *rfds, fd_set *wfds,
			       fd_set *efds, struct timespec *timeout,
			       sigset_t *sigmask);
static void event_loop_process_native (struct terminal *terminal);

#ifdef HAVE_MACGUI
/* macOS bridge: the native event loop iteration is defined in
   macappkit.m and called through a C-compatible function pointer.  */
extern void mac_run_loop_run_once (CFTimeInterval timeout);
extern int mac_select (int, fd_set *, fd_set *, fd_set *,
		       struct timespec *, sigset_t *);
extern void mac_handle_alarm_signal (void);
extern int mac_get_select_fd (void);
#endif /* HAVE_MACGUI */


/***********************************************************************
		   Per-terminal event loop state
***********************************************************************/

struct evloop_state
{
  /* No terminal-specific state yet.  We use sync_get_* accessors
     to access the sync layer's state.  */
};

void
event_loop_init (struct terminal *terminal)
{
  struct evloop_state *es;

  if (!terminal->dual_thread_p)
    return;

  es = xzalloc (sizeof *es);
  terminal->evloop_state = es;
}

void
event_loop_deinit (struct terminal *terminal)
{
  struct evloop_state *es = terminal->evloop_state;

  if (!es)
    return;

  xfree (es);
  terminal->evloop_state = NULL;
}

int
event_loop_wakeup_fd (struct terminal *terminal)
{
  struct sync_wakeup *w = sync_get_wakeup (terminal);
  if (!w)
    return -1;
  return sync_wakeup_fd (w);
}

void
event_loop_set_buffer_access_restricted (struct terminal *terminal,
					 bool restricted)
{
  sync_set_buffer_access_restricted (terminal, restricted);
}


/***********************************************************************
		      Fallback: single-threaded select
***********************************************************************/

static int
do_fallback_select (struct terminal *terminal,
		    int nfds, fd_set *rfds, fd_set *wfds,
		    fd_set *efds, struct timespec *timeout,
		    sigset_t *sigmask)
{
  return thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);
}


/***********************************************************************
		      Thread-aware select

   Pattern (from mac_select in macappkit.m):

   Phase 1 — Quick poll: run GUI event pump once (0-timeout) while
     doing 0-timeout pselect on Emacs side.  If events pending, EINTR.

   Phase 2 — Blocking wait: run GUI event loop on GUI thread while
     Emacs thread does blocking pselect.  GUI writes to wakeup fd.

   Phase 3 — After pselect returns, process leftover GUI work.
***********************************************************************/

int
event_loop_select (struct terminal *terminal,
		   int nfds, fd_set *rfds, fd_set *wfds, fd_set *efds,
		   struct timespec *timeout, sigset_t *sigmask)
{
  /* Fallback for single-threaded terminals.  */
  if (!terminal || !terminal->dual_thread_p
      || gui_thread_p (terminal))
    return do_fallback_select (terminal, nfds, rfds, wfds, efds,
			       timeout, sigmask);

  emacs_assert_thread (terminal);

#ifdef HAVE_MACGUI
  /* macOS: delegate to existing mac_select (Phase 2 integration).  */
  return mac_select (nfds, rfds, wfds, efds, timeout, sigmask);
#else
  /* Generic POSIX fallback until per-platform porting.  */
  return do_fallback_select (terminal, nfds, rfds, wfds, efds,
			     timeout, sigmask);
#endif
}


/***********************************************************************
		      GUI thread event loop

   Main processing loop for the GUI thread.  Waits for work from the
   Emacs thread (via sync semaphore) and pumps native events between
   work items.

   Runs on the GUI thread.  Does not return (process exit or terminal
   deletion stop it).
***********************************************************************/

void
event_loop_run_gui (struct terminal *terminal)
{
  sync_sem_pair *sp;

  gui_assert_thread (terminal);

  sp = sync_get_sem_pair (terminal);
  if (!sp)
    return;  /* Single-threaded terminal, nothing to do.  */

  /* Main GUI thread loop.  */
  while (true)
    {
      bool more_work;

      /* Wait for work from Emacs thread.  */
      sync_sem_pair_wait (sp, 0);

      /* Process all queued work items.  */
      do
	{
	  more_work = sync_gui_process_one (terminal);
	}
      while (more_work);

      /* Process native events between work items.  */
      event_loop_process_native (terminal);
    }
}

/* Process one native event pump iteration.
   Platform-specific hook; called between cross-thread work items.
   Must NOT block for extended periods.  */
static void
event_loop_process_native (struct terminal *terminal)
{
#ifdef HAVE_MACGUI
  /* macOS: run one iteration of NSRunLoop to process pending
     NSEvents without blocking.  */
  mac_run_loop_run_once (0.0);
#else
  /* Other platforms: no native event pump yet.  */
#endif
}

/* Process one work item and re-enter the GUI loop.
   Called from sync_call_on_emacs_thread when the GUI thread needs to
   dispatch Lisp work then return to processing.  */
void
event_loop_gui_process (struct terminal *terminal)
{
  sync_sem_pair *sp = sync_get_sem_pair (terminal);

  gui_assert_thread (terminal);
  if (!sp)
    return;

  /* Signal Lisp thread that we're ready for its work.  */
  sync_sem_pair_signal (sp, 1);

  /* Wait for the next work item from the Lisp thread.
     This is the inner loop of mac_within_lisp style dispatch.  */
  sync_sem_pair_wait (sp, 0);

  /* Process one work item.  */
  sync_gui_process_one (terminal);
}
