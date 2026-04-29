/* Cross-thread synchronization primitives for dual-thread UI model.
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
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#ifdef HAVE_EVENTFD
#include <sys/eventfd.h>
#endif
#include <sys/socket.h>

#include "lisp.h"
#include "termhooks.h"
#include "thread.h"
#include "systhread.h"
#include "sync.h"

/* Forward declarations for internal per-terminal helpers.  */
static void process_deferred_lisp_queue (struct terminal *terminal);
static void inner_lisp_wrapper_fn (void *data);

/* Forward declaration from event-loop.c.  */
extern void event_loop_gui_process (struct terminal *terminal);


/***********************************************************************
		       Thread identity
***********************************************************************/

bool
gui_thread_p (const struct terminal *terminal)
{
#ifdef HAVE_MACGUI
  /* On macOS, the GUI thread is the main/initial thread.  */
  extern bool mac_gui_thread_p (void);
  return mac_gui_thread_p ();
#elif defined THREADS_ENABLED && defined HAVE_PTHREAD
  if (terminal && terminal->dual_thread_p)
    return pthread_equal (pthread_self (), terminal->gui_thread_id);
  return false;
#else
  /* Single-threaded: the only thread is both GUI and Emacs thread.  */
  return true;
#endif
}

void
gui_assert_thread (const struct terminal *terminal)
{
  if (!gui_thread_p (terminal))
    emacs_abort ();
}

bool
emacs_thread_p (const struct terminal *terminal)
{
#ifdef HAVE_MACGUI
  extern bool mac_gui_thread_p (void);
  return initialized && !mac_gui_thread_p ();
#elif defined THREADS_ENABLED && defined HAVE_PTHREAD
  if (terminal && terminal->dual_thread_p)
    return !pthread_equal (pthread_self (), terminal->gui_thread_id);
  return true;
#else
  return true;
#endif
}

void
emacs_assert_thread (const struct terminal *terminal)
{
  if (!emacs_thread_p (terminal))
    emacs_abort ();
}


/***********************************************************************
		     Block queue implementation

   Thread-safe queue of (fn, data) pairs.  Uses a singly-linked list
   with mutex protection.
***********************************************************************/

struct sync_block_queue_node
{
  sync_block_fn fn;
  void *data;
  struct sync_block_queue_node *next;
};

struct sync_block_queue
{
  struct sync_block_queue_node *head;
  struct sync_block_queue_node *tail;
  sys_mutex_t lock;
  ptrdiff_t count;
};

sync_block_queue *
sync_block_queue_create (void)
{
  sync_block_queue *q = xmalloc (sizeof *q);
  q->head = NULL;
  q->tail = NULL;
  q->count = 0;
  sys_mutex_init (&q->lock);
  return q;
}

void
sync_block_queue_destroy (sync_block_queue *q)
{
  if (!q)
    return;

  eassert (q->count == 0);

  /* Free any remaining nodes (shouldn't happen with assert above).  */
  struct sync_block_queue_node *node = q->head;
  while (node)
    {
      struct sync_block_queue_node *next = node->next;
      xfree (node);
      node = next;
    }

  xfree (q);
}

void
sync_block_queue_push (sync_block_queue *q,
		       sync_block_fn fn, void *data)
{
  struct sync_block_queue_node *node = xmalloc (sizeof *node);
  node->fn = fn;
  node->data = data;
  node->next = NULL;

  sys_mutex_lock (&q->lock);

  if (q->tail)
    q->tail->next = node;
  else
    q->head = node;
  q->tail = node;
  q->count++;

  sys_mutex_unlock (&q->lock);
}

bool
sync_block_queue_pop (sync_block_queue *q,
		      sync_block_fn *fn, void **data)
{
  bool result = false;

  sys_mutex_lock (&q->lock);

  struct sync_block_queue_node *node = q->head;
  if (node)
    {
      q->head = node->next;
      if (!q->head)
	q->tail = NULL;
      q->count--;

      if (fn) *fn = node->fn;
      if (data) *data = node->data;
      xfree (node);
      result = true;
    }

  sys_mutex_unlock (&q->lock);

  return result;
}

ptrdiff_t
sync_block_queue_count (const sync_block_queue *q)
{
  return q->count;
}


/***********************************************************************
		   Semaphore pair implementation

   Bidirectional semaphore using pthreads.  Index 0 wakes GUI thread,
   index 1 wakes Lisp thread.  Avoids the need for macOS-specific
   dispatch_semaphore_t in the core abstraction.
***********************************************************************/

struct sync_sem_pair
{
  sys_mutex_t mutex;
  sys_cond_t cond[2];   /* cond[0] = GUI, cond[1] = Lisp */
  int count[2];          /* 0 = no signal, >0 = signals available */
};

sync_sem_pair *
sync_sem_pair_create (void)
{
  sync_sem_pair *sp = xmalloc (sizeof *sp);

  sys_mutex_init (&sp->mutex);
  sys_cond_init (&sp->cond[0]);
  sys_cond_init (&sp->cond[1]);
  sp->count[0] = 0;
  sp->count[1] = 0;

  return sp;
}

void
sync_sem_pair_destroy (sync_sem_pair *sp)
{
  if (!sp)
    return;

  xfree (sp);
}

void
sync_sem_pair_wait (sync_sem_pair *sp, int index)
{
  sys_mutex_lock (&sp->mutex);
  while (sp->count[index] <= 0)
    sys_cond_wait (&sp->cond[index], &sp->mutex);
  sp->count[index]--;
  sys_mutex_unlock (&sp->mutex);
}

void
sync_sem_pair_signal (sync_sem_pair *sp, int index)
{
  sys_mutex_lock (&sp->mutex);
  sp->count[index]++;
  sys_cond_signal (&sp->cond[index]);
  sys_mutex_unlock (&sp->mutex);
}


/***********************************************************************
		     Wakeup fd implementation

   Provides a file descriptor that becomes readable when signaled.
   Used to break out of pselect/select from another thread.
***********************************************************************/

struct sync_wakeup
{
#if defined HAVE_EVENTFD
  int fd;			/* Linux eventfd (self-signaling) */
#else
  int fds[2];			/* POSIX socketpair */
#endif
};

sync_wakeup *
sync_wakeup_create (void)
{
  sync_wakeup *w = xmalloc (sizeof *w);

#if defined HAVE_EVENTFD
  w->fd = eventfd (0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (w->fd < 0)
    {
      xfree (w);
      return NULL;
    }
#else
  if (socketpair (AF_UNIX, SOCK_STREAM, 0, w->fds) < 0)
    {
      xfree (w);
      return NULL;
    }
  for (int i = 0; i < 2; i++)
    {
      int flags = fcntl (w->fds[i], F_GETFL, 0);
      fcntl (w->fds[i], F_SETFL, flags | O_NONBLOCK);
      flags = fcntl (w->fds[i], F_GETFD, 0);
      fcntl (w->fds[i], F_SETFD, flags | FD_CLOEXEC);
    }
#endif

  return w;
}

void
sync_wakeup_destroy (sync_wakeup *w)
{
  if (!w)
    return;

#if defined HAVE_EVENTFD
  close (w->fd);
#else
  close (w->fds[0]);
  close (w->fds[1]);
#endif

  xfree (w);
}

int
sync_wakeup_fd (const sync_wakeup *w)
{
#if defined HAVE_EVENTFD
  return w->fd;
#else
  return w->fds[0];		/* Read end */
#endif
}

int
sync_wakeup_signal_fd (const sync_wakeup *w)
{
#if defined HAVE_EVENTFD
  return w->fd;
#else
  return w->fds[1];		/* Write end */
#endif
}

void
sync_wakeup_signal (sync_wakeup *w)
{
#if defined HAVE_EVENTFD
  uint64_t val = 1;
  ssize_t r;
  do
    r = write (w->fd, &val, sizeof (val));
  while (r < 0 && errno == EINTR);
#else
  ssize_t r;
  do
    r = write (w->fds[1], "", 1);
  while (r < 0 && errno == EINTR);
#endif
}

void
sync_wakeup_clear (sync_wakeup *w)
{
#if defined HAVE_EVENTFD
  uint64_t val;
  ssize_t r;
  do
    r = read (w->fd, &val, sizeof (val));
  while (r < 0 && errno == EINTR);
#else
  char buf[64];
  ssize_t r;
  do
    r = read (w->fds[0], buf, sizeof (buf));
  while (r > 0 || (r < 0 && errno == EINTR));
#endif
}


/***********************************************************************
		   Per-terminal synchronization state

   Each terminal with dual_thread_p == true has a sync_state struct
   containing all queues and synchronization primitives needed for
   cross-thread dispatch.
***********************************************************************/

struct sync_state
{
  /* Bidirectional semaphore pair.  Index 0 signals GUI thread,
     index 1 signals Lisp thread.  */
  sync_sem_pair *sp;

  /* Block queues for cross-thread dispatch.  */
  sync_block_queue *gui_queue;		 /* Lisp -> GUI */
  sync_block_queue *lisp_queue;		 /* GUI -> Lisp (inner eval) */
  sync_block_queue *deferred_lisp_queue; /* GUI -> Lisp (deferred) */

  /* Wakeup object to break the Lisp thread's select.  */
  sync_wakeup *wakeup;

  /* When true, buffer/glyph-matrix access from GUI thread requires
     the GIL trylock (because other Lisp threads may be running).  */
  bool buffer_access_restricted;

  /* Next command for the select loop.  Abstract over the
     MAC_SELECT_COMMAND_{TERMINATE,SUSPEND} pattern.  */
  enum
  {
    SYNC_SELECT_COMMAND_NONE = 0,
    SYNC_SELECT_COMMAND_TERMINATE = 1 << 0,
    SYNC_SELECT_COMMAND_SUSPEND = 1 << 1,
    SYNC_SELECT_COMMAND_WORK = 1 << 2,
  } select_next_command;

  /* Guards buffer/glyph matrix access.  */
  sys_mutex_t gil_mutex;  /* trylock from GUI thread; always from Lisp */
  bool gil_held_by_gui;
};

void
sync_init_terminal (struct terminal *terminal)
{
  struct sync_state *s;

  if (!terminal->dual_thread_p)
    return;

  s = xzalloc (sizeof *s);
  s->sp = sync_sem_pair_create ();
  s->gui_queue = sync_block_queue_create ();
  s->lisp_queue = sync_block_queue_create ();
  s->deferred_lisp_queue = sync_block_queue_create ();
  s->wakeup = sync_wakeup_create ();
  s->buffer_access_restricted = false;
  s->select_next_command = SYNC_SELECT_COMMAND_NONE;
  sys_mutex_init (&s->gil_mutex);
  s->gil_held_by_gui = false;

  terminal->sync_state = s;
}

void
sync_deinit_terminal (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;

  if (!s)
    return;

  eassert (sync_block_queue_count (s->gui_queue) == 0);
  eassert (sync_block_queue_count (s->lisp_queue) == 0);
  eassert (sync_block_queue_count (s->deferred_lisp_queue) == 0);

  sync_block_queue_destroy (s->gui_queue);
  sync_block_queue_destroy (s->lisp_queue);
  sync_block_queue_destroy (s->deferred_lisp_queue);
  sync_sem_pair_destroy (s->sp);
  sync_wakeup_destroy (s->wakeup);
  xfree (s);
  terminal->sync_state = NULL;
}

/* Dequeue and run all entries from deferred_lisp_queue.  */
static void
process_deferred_lisp_queue (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;
  sync_block_fn fn;
  void *data;

  while (sync_block_queue_pop (s->deferred_lisp_queue, &fn, &data))
    {
      if (fn)
	fn (data);
    }
}

/* Run one GUI work item: dequeue from gui_queue, execute, signal
   completion to the Lisp thread.  Returns true if more work may be
   pending.  */
bool
sync_gui_process_one (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;
  sync_block_fn fn;
  void *data;

  if (!sync_block_queue_pop (s->gui_queue, &fn, &data))
    return false;  /* No work.  */

  eassert (fn != NULL);
  fn (data);
  sync_sem_pair_signal (s->sp, 1);  /* Signal Lisp thread */
  return sync_block_queue_count (s->gui_queue) > 0;
}


/***********************************************************************
		   Cross-thread dispatch: public API

  Each function implements one of the dispatch patterns from the
  emacs-mac port, using the generic sync primitives.

  Single-threaded fallback: if terminal is NULL or dual_thread_p is
  false, all dispatch functions simply call fn(data) directly.
***********************************************************************/

void
sync_call_on_gui_thread (struct terminal *terminal,
			 sync_block_fn fn, void *data)
{
  struct sync_state *s;

  /* Single-threaded fallback.  */
  if (!terminal || !terminal->dual_thread_p
      || gui_thread_p (terminal))
    {
      fn (data);
      return;
    }

  s = terminal->sync_state;
  eassert (s != NULL);
  emacs_assert_thread (terminal);

  /* Enqueue work for GUI thread.  */
  sync_block_queue_push (s->gui_queue, fn, data);

  /* Wake GUI thread.  */
  sync_sem_pair_signal (s->sp, 0);

  /* Wait for GUI thread to signal completion.  */
  sync_sem_pair_wait (s->sp, 1);

  /* Process any deferred Lisp work queued by GUI thread.  */
  process_deferred_lisp_queue (terminal);
}

void
sync_defer_to_gui_thread (struct terminal *terminal,
			  sync_block_fn fn, void *data)
{
  struct sync_state *s;

  if (!terminal || !terminal->dual_thread_p
      || gui_thread_p (terminal))
    {
      fn (data);
      return;
    }

  s = terminal->sync_state;
  eassert (s != NULL);
  emacs_assert_thread (terminal);

  sync_block_queue_push (s->gui_queue, fn, data);
  sync_sem_pair_signal (s->sp, 0);
}

void
sync_call_on_emacs_thread (struct terminal *terminal,
			   sync_block_fn fn, void *data)
{
  struct sync_state *s;

  if (!terminal || !terminal->dual_thread_p
      || emacs_thread_p (terminal))
    {
      fn (data);
      return;
    }

  s = terminal->sync_state;
  eassert (s != NULL);
  gui_assert_thread (terminal);

  sync_block_queue_push (s->lisp_queue, fn, data);
  sync_sem_pair_signal (s->sp, 1);

  /* Re-enter the GUI loop to process Lisp-thread work and wait
     for the dispatch to complete.  Defined in event-loop.c.  */
  event_loop_gui_process (terminal);
}

void
sync_defer_to_emacs_thread (struct terminal *terminal,
			    sync_block_fn fn, void *data)
{
  struct sync_state *s;

  if (!terminal || !terminal->dual_thread_p
      || emacs_thread_p (terminal))
    {
      fn (data);
      return;
    }

  s = terminal->sync_state;
  eassert (s != NULL);
  gui_assert_thread (terminal);

  sync_block_queue_push (s->deferred_lisp_queue, fn, data);
}

/* Wrapper used by sync_call_on_gui_thread_allowing_inner_lisp.
   Sets a completion flag after running the wrapped function, so the
   Emacs thread can detect completion while processing inner Lisp
   evaluations.  */
static void
inner_lisp_wrapper_fn (void *data)
{
  struct {
    sync_block_fn fn;
    void *data;
    volatile bool completed;
  } *wrapper = data;

  wrapper->fn (wrapper->data);
  wrapper->completed = true;
}

void
sync_call_on_gui_thread_allowing_inner_lisp
  (struct terminal *terminal, sync_block_fn fn, void *data)
{
  struct sync_state *s;
  struct {
    sync_block_fn fn;
    void *data;
    volatile bool completed;
  } wrapper;

  if (!terminal || !terminal->dual_thread_p
      || gui_thread_p (terminal))
    {
      fn (data);
      return;
    }

  s = terminal->sync_state;
  eassert (s != NULL);
  emacs_assert_thread (terminal);

  wrapper.fn = fn;
  wrapper.data = data;
  wrapper.completed = false;

  /* Enqueue and wake GUI thread.  We can't use sync_call_on_gui_thread
     here because it would wait for completion before processing inner
     Lisp evaluations.  Instead, do the dispatch manually.  */
  sync_block_queue_push (s->gui_queue,
			 (sync_block_fn) inner_lisp_wrapper_fn, &wrapper);
  sync_sem_pair_signal (s->sp, 0);

  /* Wait for completion, processing inner Lisp evaluations from the
     GUI thread when available (e.g., modal dialog callbacks).  */
  while (!wrapper.completed)
    {
      sync_block_fn inner_fn;
      void *inner_data;

      /* Check for inner Lisp work from GUI thread.  */
      sync_block_queue_pop (s->lisp_queue, &inner_fn, &inner_data);
      if (inner_fn)
	inner_fn (inner_data);

      /* Ping GUI thread and wait for ack.  */
      sync_sem_pair_signal (s->sp, 0);
      sync_sem_pair_wait (s->sp, 1);
    }

  process_deferred_lisp_queue (terminal);
}


/***********************************************************************
		   GIL trylock for GUI thread

  Generalized from the mac-specific thread_try_acquire_global_lock().
  When multiple Lisp threads exist, the GUI thread must trylock the
  GIL before accessing buffer/glyph matrix data.
***********************************************************************/

int
sync_try_acquire_global_lock (struct terminal *terminal)
{
  struct sync_state *s;

  if (!terminal || !terminal->dual_thread_p)
    return 0;

  s = terminal->sync_state;
  if (!s || !s->buffer_access_restricted)
    return 0;

  /* Call the actual global lock function from thread.c.  */
  return gui_try_acquire_global_lock ();
}

int
sync_release_global_lock (struct terminal *terminal)
{
  struct sync_state *s;

  if (!terminal || !terminal->dual_thread_p)
    return 0;

  s = terminal->sync_state;
  if (!s || !s->buffer_access_restricted)
    return 0;

  return gui_release_global_lock ();
}

bool
sync_buffer_access_restricted_p (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;
  return s && s->buffer_access_restricted;
}

/* Return the wakeup object for TERMINAL.  */
struct sync_wakeup *
sync_get_wakeup (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;
  return s ? s->wakeup : NULL;
}

/* Return the semaphore pair for TERMINAL.  */
struct sync_sem_pair *
sync_get_sem_pair (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;
  return s ? s->sp : NULL;
}

/* Return the GUI work queue for TERMINAL.  */
struct sync_block_queue *
sync_get_gui_queue (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;
  return s ? s->gui_queue : NULL;
}

/* Return the Lisp work queue for TERMINAL.  */
struct sync_block_queue *
sync_get_lisp_queue (struct terminal *terminal)
{
  struct sync_state *s = terminal->sync_state;
  return s ? s->lisp_queue : NULL;
}

void
sync_set_buffer_access_restricted (struct terminal *terminal, bool flag)
{
  struct sync_state *s = terminal->sync_state;
  if (s)
    s->buffer_access_restricted = flag;
}
