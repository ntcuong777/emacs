/* Filesystem notifications support with macOS FSEvents API.

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

#include <CoreServices/CoreServices.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include "lisp.h"
#include "keyboard.h"
#include "process.h"


/* Watch list.  Each element is:
   (DESCRIPTOR FILE DIR DIRP FLAGS CALLBACK STREAM-ID RESOLVED_DIR)
   FILE  -- the original path passed to fsevents-add-watch (file or dir).
   DIR   -- the original directory namespace for this logical watch.
   DIRP  -- non-nil if FILE was originally a directory watch.
   FLAGS -- the requested event flags list.
   CALLBACK -- the Lisp callback function.
   STREAM-ID -- fixnum token of the native stream serving this watch.  */
static Lisp_Object watch_list;
/* Native stream registry.  Each element is:
   (STREAM-ID STREAMREF ROOT REFCOUNT RETIRED-TO RETIRED-WATCHES)
   STREAM-ID -- fixnum token used by the callback thread.
   STREAMREF -- opaque FSEventStreamRef stored via make_mint_ptr.
   ROOT -- physical directory path covered by the native stream.
   REFCOUNT -- number of logical watches using this stream.
   RETIRED-TO -- nil for active streams, or the replacement stream-id
                 kept alive while queued raw batches are drained.
   RETIRED-WATCHES -- descriptors of watches moved off a retired stream,
                      used to replay queued batches only to those watches.  */
static Lisp_Object stream_list;

/* Self-pipe used to wake the Emacs event loop from pselect when
   the FSEvents callback fires.  */
static int fsevents_pipe[2] = { -1, -1 };

/* Monotonically increasing descriptor counter.  */
static int next_desc;
static int next_stream_id;

/* Promote sibling stream roots to a shared parent stream once enough
   disjoint siblings accumulate under the same directory.  */
enum { FSEVENTS_SIBLING_PROMOTION_THRESHOLD = 8 };

/* Accessor macros for watch_object fields.
   Format: (DESC FILE DIR TYPE FLAGS CALLBACK STREAM-ID RESOLVED_DIR)
   TYPE is Qt for directory watches, Qnil for file watches, or
   Qsymlink for symlink-leaf watches (monitor the link entry itself,
   suppress all events except attribute changes).
   RESOLVED_DIR holds the physical path (symlinks resolved) used for
   the FSEventStream and event filtering.  DIR holds the caller's
   original path, used for translating event paths back to the
   caller's namespace.  */
#define WATCH_DESC(w)         (XCAR (w))
#define WATCH_FILE(w)         (XCAR (XCDR (w)))
#define WATCH_DIR(w)          (XCAR (XCDR (XCDR (w))))
#define WATCH_TYPE(w)         (XCAR (XCDR (XCDR (XCDR (w)))))
#define WATCH_FLAGS(w)        (XCAR (XCDR (XCDR (XCDR (XCDR (w))))))
#define WATCH_CALLBACK(w)     (XCAR (XCDR (XCDR (XCDR (XCDR (XCDR (w)))))))
#define WATCH_STREAM_ID(w)    (XCAR (XCDR (XCDR (XCDR (XCDR (XCDR (XCDR (w))))))))
#define WATCH_RESOLVED_DIR(w) (XCAR (XCDR (XCDR (XCDR (XCDR (XCDR (XCDR (XCDR (w)))))))))
#define STREAM_ID(s)          (XCAR (s))
#define STREAM_REF(s)         (XCAR (XCDR (s)))
#define STREAM_ROOT(s)        (XCAR (XCDR (XCDR (s))))
#define STREAM_REFCOUNT(s)    (XCAR (XCDR (XCDR (XCDR (s)))))
#define STREAM_RETIRED_TO(s)  (XCAR (XCDR (XCDR (XCDR (XCDR (s))))))
#define STREAM_RETIRED_WATCHES(s) (XCAR (XCDR (XCDR (XCDR (XCDR (XCDR (s)))))))
#define PENDING_DESC(p)      (XCAR (p))
#define PENDING_FILE(p)      (XCAR (XCDR (p)))
#define PENDING_ACTION(p)    (XCAR (XCDR (XCDR (p))))
#define PENDING_BATCH_IDX(p) XFIXNUM (XCAR (XCDR (XCDR (XCDR (p)))))
#define PENDING_ACTIVE(p)       (XCAR (XCDR (XCDR (XCDR (XCDR (p))))))
#define PENDING_SET_INACTIVE(p) XSETCAR (XCDR (XCDR (XCDR (XCDR (p)))), Qnil)

void globals_of_fsevents (void);
void syms_of_fsevents (void);
static void fsevents_close_pipe (void);
static void fsevents_stream_callback (ConstFSEventStreamRef streamRef,
                                      void *clientCallBackInfo,
                                      size_t numEvents,
                                      void *eventPaths,
                                      const FSEventStreamEventFlags eventFlags[],
                                      const FSEventStreamEventId eventIds[]);
static bool fsevents_path_prefix_p (Lisp_Object parent, Lisp_Object child);
static bool fsevents_same_path_p (Lisp_Object file1, Lisp_Object file2);
static Lisp_Object fsevents_parent_dir (Lisp_Object dir);
static bool fsevents_stream_active_p (Lisp_Object stream_entry);
static Lisp_Object fsevents_find_covering_stream (Lisp_Object resolved_dir);
static ptrdiff_t fsevents_count_sibling_streams (Lisp_Object parent_dir);
static Lisp_Object fsevents_choose_stream_root (Lisp_Object resolved_dir);
static Lisp_Object fsevents_make_stream (Lisp_Object resolved_dir);
static void fsevents_retarget_descendant_streams (Lisp_Object stream_entry,
                                                  Lisp_Object resolved_dir);
static void fsevents_reap_retired_streams_if_idle (void);


/* ================================================================
   Raw event batch queue (thread-safe).

   The FSEvents callback fires on a GCD dispatch queue thread and
   must not touch Lisp objects.  It stores raw C data (paths as
   UTF-8 strings, event flags) into a linked list of batches
   protected by a mutex.  A byte written to the self-pipe then wakes
   the Emacs main thread, which dequeues the raw batches and does
   all Lisp-level processing (rename pairing, filtering, event
   generation).  */

struct raw_event
{
  char *path;                       /* strdup'd UTF-8 path.  */
  FSEventStreamEventFlags flags;
  bool path_exists;                 /* lstat snapshot at callback time.  */
};

struct raw_batch
{
  int stream_id;
  size_t num_events;
  struct raw_event *events;         /* Array of num_events entries.  */
  struct raw_batch *next;
};

static pthread_mutex_t raw_queue_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct raw_batch *raw_queue_head;
static struct raw_batch *raw_queue_tail;

static void raw_batch_free (struct raw_batch *batch);
static void raw_queue_push_without_wake (struct raw_batch *batch);

static bool fsevents_debug_inject_batch_during_read;
static int fsevents_debug_inject_stream_id;

/* Performance instrumentation, disabled by default so production hot
   paths pay only a predictable false branch.  The enable flag and
   LSTAT_CALLS are read/written from the GCD callback thread as well
   as the main thread, so they use atomic builtins (matching
   src/android.c's use of __atomic_* on plain scalar globals).  The
   other three counters are only ever touched on the main thread.  */
static bool fsevents_debug_performance_counters_enabled;
static uintmax_t fsevents_debug_batch_prepares;
static uintmax_t fsevents_debug_watch_dispatches;
static uintmax_t fsevents_debug_pending_probes;
static uintmax_t fsevents_debug_lstat_calls;

static void
fsevents_debug_count_batch_prepare (void)
{
  if (__atomic_load_n (&fsevents_debug_performance_counters_enabled,
                       __ATOMIC_ACQUIRE))
    fsevents_debug_batch_prepares++;
}

static void
fsevents_debug_count_watch_dispatch (void)
{
  if (__atomic_load_n (&fsevents_debug_performance_counters_enabled,
                       __ATOMIC_ACQUIRE))
    fsevents_debug_watch_dispatches++;
}

static void
fsevents_debug_count_pending_probe (void)
{
  if (__atomic_load_n (&fsevents_debug_performance_counters_enabled,
                       __ATOMIC_ACQUIRE))
    fsevents_debug_pending_probes++;
}

static struct raw_batch *
raw_batch_make_empty (int stream_id)
{
  struct raw_batch *batch = malloc (sizeof *batch);
  if (!batch)
    memory_full (SIZE_MAX);

  batch->stream_id = stream_id;
  batch->num_events = 0;
  batch->events = NULL;
  batch->next = NULL;
  return batch;
}

/* Enqueue a raw batch and wake the self-pipe (called from the GCD
   dispatch queue thread).  The pipe write is done under the same mutex that
   fsevents_close_pipe acquires before invalidating the pipe FDs, so
   we never write to a closed/reused descriptor.  */
static void
raw_queue_push_1 (struct raw_batch *batch, bool wake)
{
  batch->next = NULL;
  pthread_mutex_lock (&raw_queue_mutex);
  /* If the pipe is already torn down (last watch removed), there is
     no read FD to drain this batch and no cleanup path.  Free it
     immediately instead of orphaning it on the queue.  This handles
     the race where an in-flight GCD callback acquires the mutex after
     fsevents_close_pipe has already invalidated the pipe FDs.  */
  if (fsevents_pipe[1] < 0)
    {
      pthread_mutex_unlock (&raw_queue_mutex);
      raw_batch_free (batch);
      return;
    }
  if (raw_queue_tail)
    raw_queue_tail->next = batch;
  else
    raw_queue_head = batch;
  raw_queue_tail = batch;
  if (wake)
    {
      /* Wake the event loop while still holding the lock.  */
      char byte = 0;
      (void) write (fsevents_pipe[1], &byte, 1);
    }
  pthread_mutex_unlock (&raw_queue_mutex);
}

static void
raw_queue_push (struct raw_batch *batch)
{
  raw_queue_push_1 (batch, true);
}

static void
raw_queue_push_without_wake (struct raw_batch *batch)
{
  raw_queue_push_1 (batch, false);
}

/* Dequeue all pending batches (called from the main thread).
   Returns the head of the detached list.  */
static struct raw_batch *
raw_queue_drain (void)
{
  pthread_mutex_lock (&raw_queue_mutex);
  struct raw_batch *head = raw_queue_head;
  raw_queue_head = NULL;
  raw_queue_tail = NULL;
  pthread_mutex_unlock (&raw_queue_mutex);
  return head;
}

static bool
raw_queue_empty_p (void)
{
  pthread_mutex_lock (&raw_queue_mutex);
  bool empty = (raw_queue_head == NULL);
  pthread_mutex_unlock (&raw_queue_mutex);
  return empty;
}

static void
raw_queue_rearm_if_needed (void)
{
  pthread_mutex_lock (&raw_queue_mutex);
  if (raw_queue_head != NULL && fsevents_pipe[1] >= 0)
    {
      /* If the pipe already has unread bytes this may fail with EAGAIN,
         which is fine: a later read callback is already pending.  */
      char byte = 0;
      (void) write (fsevents_pipe[1], &byte, 1);
    }
  pthread_mutex_unlock (&raw_queue_mutex);
}

/* Free a raw_batch and its contents.  */
static void
raw_batch_free (struct raw_batch *batch)
{
  for (size_t i = 0; i < batch->num_events; i++)
    free (batch->events[i].path);
  free (batch->events);
  free (batch);
}


/* ================================================================
   Dispatch queue for FSEvents callbacks.

   FSEvents callbacks are dispatched on a serial GCD queue rather
   than a manual CFRunLoop thread.  This avoids the race between
   CFRunLoopGetCurrent() and CFRunLoopRun() that caused
   FSEventStreamStart to fail intermittently, and works in all
   Emacs configurations: GUI, daemon, terminal, and batch.  */

static dispatch_queue_t fsevents_queue;

static void
fsevents_dispatch_sync_noop (void *ignored)
{
}

static void
fsevents_ensure_queue (void)
{
  if (fsevents_queue)
    return;
  fsevents_queue
    = dispatch_queue_create ("org.gnu.emacs.fsevents",
			     DISPATCH_QUEUE_SERIAL);
  if (!fsevents_queue)
    report_file_notify_error ("Cannot create FSEvents dispatch queue",
			      Qnil);
}

static void
fsevents_sync_callback_queue (void)
{
  if (fsevents_queue)
    dispatch_sync_f (fsevents_queue, NULL, fsevents_dispatch_sync_noop);
}


/* ================================================================
   Path translation.

   FSEvents reports physical paths (all symlinks resolved).  When the
   caller's path contains intermediate symlinks, event paths must be
   translated back to the caller's namespace so that path comparisons
   and event reporting use the path the caller originally provided.

   The translation is a prefix replacement: RESOLVED_DIR -> ORIG_DIR.
   When there are no intermediate symlinks the two are identical and
   translation is a no-op.  */

/* Translate EVENT_PATH from the physical namespace (RESOLVED_DIR
   prefix) to the caller's namespace (ORIG_DIR prefix).  Both
   directory arguments must end with '/'.  Returns EVENT_PATH
   unchanged when no translation is needed.  */
static Lisp_Object
fsevents_translate_path (Lisp_Object event_path,
			 Lisp_Object resolved_dir,
			 Lisp_Object orig_dir)
{
  Lisp_Object enc_resolved = ENCODE_FILE (resolved_dir);
  Lisp_Object enc_orig = ENCODE_FILE (orig_dir);
  ptrdiff_t rlen = SBYTES (enc_resolved);
  ptrdiff_t olen = SBYTES (enc_orig);

  /* Fast path: no translation needed.  */
  if (rlen == olen
      && memcmp (SSDATA (enc_resolved), SSDATA (enc_orig), rlen) == 0)
    return event_path;

  Lisp_Object enc_event = ENCODE_FILE (event_path);
  const char *estr = SSDATA (enc_event);
  ptrdiff_t elen = SBYTES (enc_event);

  /* Event is a child of the resolved dir.  */
  if (elen >= rlen
      && memcmp (estr, SSDATA (enc_resolved), rlen) == 0)
    return DECODE_FILE (concat2 (enc_orig,
				 make_unibyte_string (estr + rlen,
						      elen - rlen)));

  /* Event IS the resolved dir without trailing slash.  */
  if (rlen > 0 && elen == rlen - 1
      && memcmp (estr, SSDATA (enc_resolved), elen) == 0
      && SDATA (enc_resolved)[elen] == '/')
    return Fdirectory_file_name (orig_dir);

  return event_path;
}


/* ================================================================
   Watch helpers.  */

/* Find the watch object for DESCRIPTOR in watch_list.  */
static Lisp_Object
fsevents_find_watch (int descriptor)
{
  Lisp_Object desc = make_fixnum (descriptor);
  return assq_no_quit (desc, watch_list);
}

/* Return true if CHILD is equal to or contained within PARENT.
   Both paths must be directory names ending with '/'.  */
static bool
fsevents_path_prefix_p (Lisp_Object parent, Lisp_Object child)
{
  Lisp_Object encoded_parent = ENCODE_FILE (parent);
  Lisp_Object encoded_child = ENCODE_FILE (child);
  ptrdiff_t parent_len = SBYTES (encoded_parent);
  ptrdiff_t child_len = SBYTES (encoded_child);

  return (child_len >= parent_len
          && memcmp (SSDATA (encoded_parent), SSDATA (encoded_child),
                     parent_len) == 0);
}

/* Return DIR's parent directory, preserving the trailing slash.  */
static Lisp_Object
fsevents_parent_dir (Lisp_Object dir)
{
  Lisp_Object parent = Ffile_name_directory (Fdirectory_file_name (dir));
  return STRINGP (parent) ? Ffile_name_as_directory (parent) : Qnil;
}

/* Return the native stream entry whose root already covers RESOLVED_DIR.
   Prefer the deepest covering root to minimize irrelevant events.  */
static bool
fsevents_stream_active_p (Lisp_Object stream_entry)
{
  return (CONSP (stream_entry)
	  && NILP (STREAM_RETIRED_TO (stream_entry))
	  && !NILP (STREAM_REF (stream_entry)));
}

static Lisp_Object
fsevents_find_covering_stream (Lisp_Object resolved_dir)
{
  Lisp_Object best = Qnil;
  ptrdiff_t best_len = -1;

  for (Lisp_Object tail = stream_list; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object stream_entry = XCAR (tail);
      if (!fsevents_stream_active_p (stream_entry))
        continue;
      Lisp_Object root = STREAM_ROOT (stream_entry);
      if (fsevents_path_prefix_p (root, resolved_dir))
        {
          ptrdiff_t root_len = SBYTES (ENCODE_FILE (root));
          if (root_len > best_len)
            {
              best = stream_entry;
              best_len = root_len;
            }
        }
    }

  return best;
}

/* Return the number of native streams rooted at immediate children of
   PARENT_DIR.  */
static ptrdiff_t
fsevents_count_sibling_streams (Lisp_Object parent_dir)
{
  ptrdiff_t count = 0;

  for (Lisp_Object tail = stream_list; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object stream_entry = XCAR (tail);
      if (!fsevents_stream_active_p (stream_entry))
        continue;
      Lisp_Object root_parent = fsevents_parent_dir (STREAM_ROOT (stream_entry));
      if (STRINGP (root_parent) && fsevents_same_path_p (root_parent, parent_dir))
        count++;
    }

  return count;
}

/* Choose the native stream root for RESOLVED_DIR.
   Reuse an existing covering stream when possible.  Otherwise, if
   enough sibling streams already exist under the same parent,
   conservatively promote the new watch to that parent root.  */
static Lisp_Object
fsevents_choose_stream_root (Lisp_Object resolved_dir)
{
  Lisp_Object stream_entry = fsevents_find_covering_stream (resolved_dir);
  if (CONSP (stream_entry))
    return STREAM_ROOT (stream_entry);

  Lisp_Object parent_dir = fsevents_parent_dir (resolved_dir);
  if (!STRINGP (parent_dir))
    return resolved_dir;

  if (fsevents_count_sibling_streams (parent_dir)
      >= FSEVENTS_SIBLING_PROMOTION_THRESHOLD - 1)
    return parent_dir;

  return resolved_dir;
}

/* Return the stream entry for STREAM_ID, or Qnil if absent.  */
static Lisp_Object
fsevents_find_stream (int stream_id)
{
  Lisp_Object id = make_fixnum (stream_id);
  return assq_no_quit (id, stream_list);
}

/* Create a native FSEvents stream rooted at RESOLVED_DIR and register it.  */
static Lisp_Object
fsevents_make_stream (Lisp_Object resolved_dir)
{
  Lisp_Object encoded_resolved = ENCODE_FILE (resolved_dir);
  CFStringRef cf_path
    = CFStringCreateWithCString (kCFAllocatorDefault,
                                 SSDATA (encoded_resolved),
                                 kCFStringEncodingUTF8);
  if (!cf_path)
    report_file_notify_error ("Cannot create CFString for path",
                              resolved_dir);

  CFArrayRef paths_to_watch
    = CFArrayCreate (kCFAllocatorDefault,
                     (const void **) &cf_path, 1,
                     &kCFTypeArrayCallBacks);
  CFRelease (cf_path);

  FSEventStreamContext ctx;
  memset (&ctx, 0, sizeof ctx);
  int stream_id = next_stream_id++;
  ctx.info = (void *) (intptr_t) stream_id;

  FSEventStreamRef stream
    = FSEventStreamCreate (kCFAllocatorDefault,
                           fsevents_stream_callback,
                           &ctx,
                           paths_to_watch,
                           kFSEventStreamEventIdSinceNow,
                           0.01, /* latency in seconds */
                           (kFSEventStreamCreateFlagFileEvents
                            | kFSEventStreamCreateFlagNoDefer
                            | kFSEventStreamCreateFlagWatchRoot));
  CFRelease (paths_to_watch);

  if (!stream)
    report_file_notify_error ("Cannot create FSEventStream",
                              resolved_dir);

  FSEventStreamSetDispatchQueue (stream, fsevents_queue);
  if (!FSEventStreamStart (stream))
    {
      FSEventStreamInvalidate (stream);
      FSEventStreamRelease (stream);
      report_file_notify_error ("Cannot start FSEventStream",
                                resolved_dir);
    }

  Lisp_Object stream_ref = make_mint_ptr (stream);
  Lisp_Object stream_entry
    = Fcons (make_fixnum (stream_id),
             Fcons (stream_ref,
                    Fcons (resolved_dir,
                           Fcons (make_fixnum (1),
                                  Fcons (Qnil, list1 (Qnil))))));
  stream_list = Fcons (stream_entry,
                       stream_list);
  return stream_entry;
}

static void
fsevents_retire_stream (Lisp_Object stream_entry, Lisp_Object replacement_id,
                        Lisp_Object retired_watches)
{
  FSEventStreamRef stream
    = (FSEventStreamRef) xmint_pointer (STREAM_REF (stream_entry));
  FSEventStreamStop (stream);
  FSEventStreamInvalidate (stream);
  FSEventStreamRelease (stream);

  XSETCAR (XCDR (stream_entry), Qnil);
  XSETCAR (XCDR (XCDR (XCDR (XCDR (stream_entry)))), replacement_id);
  XSETCAR (XCDR (XCDR (XCDR (XCDR (XCDR (stream_entry))))), retired_watches);

  /* Wait for already-submitted callbacks on the serial dispatch queue
     to finish enqueuing their raw batches before considering this
     retired stream-id collectible.  */
  fsevents_sync_callback_queue ();
  fsevents_reap_retired_streams_if_idle ();
}

static Lisp_Object
fsevents_collect_retired_watch_descs (Lisp_Object retired_root,
                                      Lisp_Object replacement_id)
{
  Lisp_Object moved = Qnil;

  for (Lisp_Object tail = watch_list; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object watch = XCAR (tail);
      if (!EQ (WATCH_STREAM_ID (watch), replacement_id)
          || !fsevents_path_prefix_p (retired_root, WATCH_RESOLVED_DIR (watch)))
        continue;

      moved = Fcons (WATCH_DESC (watch), moved);
    }

  return moved;
}

static void
fsevents_reap_retired_streams_if_idle (void)
{
  if (!raw_queue_empty_p ())
    return;

  for (Lisp_Object tail = stream_list; CONSP (tail);)
    {
      Lisp_Object stream_entry = XCAR (tail);
      Lisp_Object next = XCDR (tail);
      if (FIXNUMP (STREAM_RETIRED_TO (stream_entry)))
        stream_list = Fdelq (stream_entry, stream_list);
      tail = next;
    }
}

/* Retarget logical watches whose native stream root is inside RESOLVED_DIR
   so they share STREAM_ENTRY instead of consuming a separate native stream.  */
static void
fsevents_retarget_descendant_streams (Lisp_Object stream_entry,
                                      Lisp_Object resolved_dir)
{
  Lisp_Object stream_id = STREAM_ID (stream_entry);
  for (Lisp_Object tail = watch_list; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object watch = XCAR (tail);
      Lisp_Object old_stream_entry
        = fsevents_find_stream (XFIXNUM (WATCH_STREAM_ID (watch)));

      if (!CONSP (old_stream_entry)
          || EQ (STREAM_ID (old_stream_entry), stream_id)
          || !fsevents_path_prefix_p (resolved_dir, STREAM_ROOT (old_stream_entry)))
        continue;

      XSETCAR (XCDR (XCDR (XCDR (XCDR (XCDR (XCDR (watch)))))), stream_id);

      XSETCAR (XCDR (XCDR (XCDR (old_stream_entry))),
               make_fixnum (XFIXNUM (STREAM_REFCOUNT (old_stream_entry)) - 1));
      if (XFIXNUM (STREAM_REFCOUNT (old_stream_entry)) == 0)
        fsevents_retire_stream
          (old_stream_entry, stream_id,
           fsevents_collect_retired_watch_descs (STREAM_ROOT (old_stream_entry),
                                                 stream_id));
      XSETCAR (XCDR (XCDR (XCDR (stream_entry))),
               make_fixnum (XFIXNUM (STREAM_REFCOUNT (stream_entry)) + 1));
    }
}

/* Remove WATCH_OBJECT from watch_list and release its native stream
   when the last logical watch detaches from it.
   FSEventStreamInvalidate automatically unschedules the stream from
   its dispatch queue (FSEvents.h: "It will be unscheduled from any
   runloops or dispatch queues upon which it had been scheduled.").
   Do NOT call FSEventStreamSetDispatchQueue(stream, NULL) before
   invalidation -- the header explicitly forbids it.  */
static void
fsevents_dispose_watch (Lisp_Object watch_object)
{
  Lisp_Object stream_entry
    = fsevents_find_stream (XFIXNUM (WATCH_STREAM_ID (watch_object)));

  if (fsevents_stream_active_p (stream_entry))
    {
      XSETCAR (XCDR (XCDR (XCDR (stream_entry))),
               make_fixnum (XFIXNUM (STREAM_REFCOUNT (stream_entry)) - 1));
      if (XFIXNUM (STREAM_REFCOUNT (stream_entry)) == 0)
        {
          FSEventStreamRef stream
            = (FSEventStreamRef) xmint_pointer (STREAM_REF (stream_entry));
          FSEventStreamStop (stream);
          FSEventStreamInvalidate (stream);
          FSEventStreamRelease (stream);
          stream_list = Fdelq (stream_entry, stream_list);
        }
    }

  watch_list = Fdelq (watch_object, watch_list);

  if (NILP (watch_list))
    fsevents_close_pipe ();
}

/* Return true if EVENT_PATH is relevant for WATCH_OBJECT.
   For a directory watch: the event path must be the directory itself
   or a direct child (not a deeper descendant).
   For a file watch: the event path must exactly match FILE.  */
static bool
fsevents_path_relevant_p (Lisp_Object watch_object, Lisp_Object event_path)
{
  Lisp_Object watched_file = WATCH_FILE (watch_object);
  Lisp_Object dir = WATCH_DIR (watch_object);
  bool watching_dir = EQ (WATCH_TYPE (watch_object), Qt);
  Lisp_Object encoded_watched_file = ENCODE_FILE (watched_file);
  Lisp_Object encoded_event_path = ENCODE_FILE (event_path);
  const char *watched_file_str = SSDATA (encoded_watched_file);
  const char *event_path_str = SSDATA (encoded_event_path);

  if (watching_dir)
    {
      Lisp_Object encoded_dir = ENCODE_FILE (dir);
      /* DIR always ends with '/'.  Check that event_path starts with
	 dir prefix.  */
      const char *dir_str = SSDATA (encoded_dir);
      size_t dir_len = strlen (dir_str);

      if (strcmp (event_path_str, watched_file_str) == 0)
	return true;

      if (strncmp (event_path_str, dir_str, dir_len) != 0)
	return false;

      const char *rest = event_path_str + dir_len;
      /* Event on the directory itself -- allow it so that delete/rename
	 events for the watched root reach file-notify--handle-event
	 and trigger the stopped path.  */
      if (*rest == '\0')
	return true;
      /* Strip trailing slash if present.  */
      size_t rest_len = strlen (rest);
      if (rest_len > 0 && rest[rest_len - 1] == '/')
	rest_len--;
      /* Check no slash in the remainder (would mean subdirectory).  */
      for (size_t i = 0; i < rest_len; i++)
	if (rest[i] == '/')
	  return false;
      return true;
    }
  else
    {
      /* File watch: exact match, tolerating a trailing slash when a
	 formerly-missing watched path now exists as a directory.  */
      size_t watched_len = strlen (watched_file_str);

      if (strcmp (event_path_str, watched_file_str) == 0)
	return true;

      return (strncmp (event_path_str, watched_file_str, watched_len) == 0
	      && event_path_str[watched_len] == '/'
	      && event_path_str[watched_len + 1] == '\0');
    }
}

/* Return true if FILE1 and FILE2 name the same path, ignoring a single
   trailing slash on non-root paths.  FSEvents can report a missing leaf
   created as a directory with a trailing slash even when the watch was
   added for the slashless path.  */
static bool
fsevents_same_path_p (Lisp_Object file1, Lisp_Object file2)
{
  if (!STRINGP (file1) || !STRINGP (file2))
    return false;

  ptrdiff_t len1 = SBYTES (file1);
  ptrdiff_t len2 = SBYTES (file2);
  const char *str1 = SSDATA (file1);
  const char *str2 = SSDATA (file2);

  if (len1 > 1 && str1[len1 - 1] == '/')
    len1--;
  if (len2 > 1 && str2[len2 - 1] == '/')
    len2--;

  return len1 == len2 && memcmp (str1, str2, len1) == 0;
}

/* Return FILE's normalized key for the O(1) pending-rename lookup
   table: FILE unchanged, except a single trailing slash is stripped
   (mirroring fsevents_same_path_p's one-trailing-slash equivalence).
   PATH must be a translated Lisp string, never a raw callback
   spelling.  */
static Lisp_Object
fsevents_same_path_key (Lisp_Object path)
{
  ptrdiff_t len = SBYTES (path);
  if (len > 1 && SDATA (path)[len - 1] == '/')
    return Fsubstring (path, make_fixnum (0), make_fixnum (SCHARS (path) - 1));
  return path;
}

/* Return true if the rename from OLD_FILE to NEW_FILE stays inside the
   watched scope of DESCRIPTOR.  Cross-boundary renames must remain
   one-sided so the read callback can resolve them to create/delete.  */
static bool
fsevents_rename_pair_relevant_p (int descriptor, Lisp_Object old_file,
				 Lisp_Object new_file)
{
  Lisp_Object watch_object = fsevents_find_watch (descriptor);

  if (!CONSP (watch_object))
    return false;

  if (fsevents_same_path_p (old_file, new_file))
    return false;

  if (!EQ (WATCH_TYPE (watch_object), Qt))
    {
      if (fsevents_same_path_p (old_file, WATCH_FILE (watch_object)))
	return true;
      return fsevents_same_path_p (new_file, WATCH_FILE (watch_object));
    }

  return (fsevents_path_relevant_p (watch_object, old_file)
	  && fsevents_path_relevant_p (watch_object, new_file));
}

/* Return true if FILE is the watched root path for WATCH_OBJECT.  */
static bool
fsevents_watch_root_p (Lisp_Object watch_object, Lisp_Object file)
{
  return fsevents_same_path_p (file, WATCH_FILE (watch_object));
}

/* Return true if EVENT_PATH lies under WATCH_OBJECT's watched root.
   Unlike fsevents_path_relevant_p, this includes deeper descendants,
   which is what stream-scoped overflow reports need.  */
static bool
fsevents_path_within_watch_root_p (Lisp_Object watch_object,
				   Lisp_Object event_path)
{
  if (!CONSP (watch_object) || !STRINGP (event_path))
    return false;

  if (fsevents_watch_root_p (watch_object, event_path))
    return true;

  if (!EQ (WATCH_TYPE (watch_object), Qt))
    return false;

  return fsevents_path_prefix_p (WATCH_DIR (watch_object),
				 Ffile_name_as_directory (event_path));
}

/* Return a one-sided event for a rename pair that crosses the watched
   boundary, or Qnil if both paths are either relevant or irrelevant.
   For file watches where the old path IS the watched file, emit a
   rename event (with the new path) instead of delete so that
   file-notify--handle-event can handle the backup/atomic-save flow
   (file-notify-test08-backup).  A plain delete would cause the
   descriptor to be removed, losing the watch on the recreated file.  */
static Lisp_Object
fsevents_cross_boundary_rename_entry (int descriptor, Lisp_Object old_file,
				      Lisp_Object new_file)
{
  Lisp_Object watch_object = fsevents_find_watch (descriptor);

  if (!CONSP (watch_object))
    return Qnil;

  bool old_relevant = fsevents_path_relevant_p (watch_object, old_file);
  bool new_relevant = fsevents_path_relevant_p (watch_object, new_file);

  if (old_relevant == new_relevant)
    return Qnil;

  if (old_relevant)
    {
      /* For file watches, a rename-out of the watched path is reported
	 as rename (not delete) so the Lisp layer can continue monitoring
	 the path after it is recreated (backup/atomic-save pattern).  */
      if (!EQ (WATCH_TYPE (watch_object), Qt)
	  && fsevents_same_path_p (old_file, WATCH_FILE (watch_object)))
	return list4 (make_fixnum (descriptor),
		      list1 (Qrename), old_file, new_file);
      return list3 (make_fixnum (descriptor),
		    list1 (Qdelete), old_file);
    }
  return list3 (make_fixnum (descriptor),
		list1 (Qcreate), new_file);
}

/* Return the fallback one-sided action for a rename event on FILE.
   PATH_EXISTS is the lstat snapshot captured at callback time.  */
static Lisp_Object
fsevents_one_sided_rename_action (bool path_exists)
{
  return path_exists ? Qcreate : Qdelete;
}

/* Return a pending rename entry for DESCRIPTOR, FILE, and BATCH_IDX
   (the index of this event within the current callback batch).
   PATH_EXISTS is the lstat snapshot captured at callback time.  The
   entry starts ACTIVE (t); resolving or pairing it later flips
   ACTIVE to nil in place rather than unlinking it from the
   chronological pending list.  */
static Lisp_Object
fsevents_make_pending_rename (int descriptor, Lisp_Object file,
			      size_t batch_idx, bool path_exists)
{
  return list5 (make_fixnum (descriptor), file,
		fsevents_one_sided_rename_action (path_exists),
		make_fixnum (batch_idx), Qt);
}

/* Return the low-level action list corresponding to FLAGS.  Set
   *IS_RENAME if the batch entry is a rename candidate.  */
static Lisp_Object
fsevents_actions_from_flags (FSEventStreamEventFlags flags, bool *is_rename)
{
  Lisp_Object actions = Qnil;

  *is_rename = false;

  /* Build the action list so that content-change transitions appear
     before terminal transitions.  Fcons prepends, so we add in
     reverse priority order: attrib < rename < delete < write < create.

     This ensures two things:
     1. When FSEvents coalesces Created|Modified into one batch entry,
        file-notify sees `created' before `changed'
        (file-notify-test03-events depends on this ordering).
     2. When FSEvents coalesces Modified|Removed (or Modified|Renamed),
        `changed' is delivered before `deleted'/`renamed'.  This matters
        because file-notify--handle-event tears down the watch on
        deleted/renamed -- if they came first, the subsequent changed
        would be dropped (file-notify-test08-backup depends on seeing
        the final content change before the rename).  */
  if (flags & (kFSEventStreamEventFlagItemInodeMetaMod
	       | kFSEventStreamEventFlagItemChangeOwner
	       | kFSEventStreamEventFlagItemXattrMod
	       | kFSEventStreamEventFlagItemFinderInfoMod))
    actions = Fcons (Qattrib, actions);
  if (flags & kFSEventStreamEventFlagItemRenamed)
    {
      actions = Fcons (Qrename, actions);
      *is_rename = true;
    }
  if (flags & kFSEventStreamEventFlagItemRemoved)
    actions = Fcons (Qdelete, actions);
  if (flags & kFSEventStreamEventFlagItemModified)
    actions = Fcons (Qwrite, actions);
  if (flags & kFSEventStreamEventFlagItemCreated)
    actions = Fcons (Qcreate, actions);

  return actions;
}

/* Resolve PENDING using the current event when it reuses the same
   pathname in the same callback batch; otherwise fall back to the
   stored one-sided action.  */
static Lisp_Object
fsevents_resolve_pending_rename (Lisp_Object pending, Lisp_Object current_file,
				 Lisp_Object current_actions,
				 Lisp_Object current_default_action)
{
  int descriptor = XFIXNUM (PENDING_DESC (pending));
  Lisp_Object file = PENDING_FILE (pending);
  Lisp_Object action = PENDING_ACTION (pending);

  if (STRINGP (current_file) && fsevents_same_path_p (file, current_file))
    {
      if (!NILP (Fmember (Qcreate, current_actions)))
	action = Qdelete;
      if (!NILP (Fmember (Qdelete, current_actions)))
	action = Qcreate;
      if (!NILP (Fmember (Qrename, current_actions)))
	action = EQ (current_default_action, Qcreate) ? Qdelete : Qcreate;
    }

  return list3 (make_fixnum (descriptor), list1 (action), file);
}

/* Append ENTRY (an active pending-rename record) to the chronological
   pending list in O(1): *PENDING_TAIL always names the last cons of
   *PENDING_HEAD, so extending it is a single XSETCDR.  Also index
   ENTRY under its normalized path in *PENDING_BY_PATH (lazily
   created), prepending to that path's bucket in O(1); buckets are
   read back in reverse-chronological order, so callers must
   Fnreverse before emitting.  *LAST_PENDING tracks only the most
   recently appended entry, the sole candidate for the
   consecutive-index rename-pair check (FSEvents guarantees rename
   pairs are consecutive batch entries).  */
static void
fsevents_pending_append (Lisp_Object *pending_head, Lisp_Object *pending_tail,
			 Lisp_Object *last_pending,
			 Lisp_Object *pending_by_path, Lisp_Object entry)
{
  Lisp_Object link = Fcons (entry, Qnil);
  if (NILP (*pending_head))
    *pending_head = link;
  else
    XSETCDR (*pending_tail, link);
  *pending_tail = link;
  *last_pending = entry;

  if (NILP (*pending_by_path))
    *pending_by_path = make_hash_table (&hashtest_equal, DEFAULT_HASH_SIZE,
					Weak_None);

  struct Lisp_Hash_Table *h = XHASH_TABLE (*pending_by_path);
  Lisp_Object key = fsevents_same_path_key (PENDING_FILE (entry));
  hash_hash_t hash;
  ptrdiff_t idx = hash_find_get_hash (h, key, &hash);
  if (idx >= 0)
    set_hash_value_slot (h, idx, Fcons (entry, HASH_VALUE (h, idx)));
  else
    hash_put (h, key, Fcons (entry, Qnil), hash);
}

/* Resolve and remove FILE's normalized-path bucket from
   PENDING_BY_PATH (a no-op if the table or bucket is absent),
   appending a resolved event to *BATCH for every still-ACTIVE entry
   in it and marking each such entry inactive.  Every pending entry
   in FILE's namesake chain lands in the same bucket, so this replaces
   the linear same-path scan of the pending list with a single hash
   lookup plus a walk bounded by that one path's history.  Returns
   true if at least one active entry was resolved.  */
static bool
fsevents_resolve_pending_bucket (Lisp_Object pending_by_path,
				 Lisp_Object file, Lisp_Object current_actions,
				 Lisp_Object current_default_action,
				 Lisp_Object *batch)
{
  if (NILP (pending_by_path) || !STRINGP (file))
    return false;

  struct Lisp_Hash_Table *h = XHASH_TABLE (pending_by_path);
  Lisp_Object key = fsevents_same_path_key (file);
  ptrdiff_t idx = hash_find (h, key);
  if (idx < 0)
    return false;

  Lisp_Object bucket = Fnreverse (HASH_VALUE (h, idx));
  hash_remove_from_table (h, key);

  bool any = false;
  for (Lisp_Object tail = bucket; CONSP (tail); tail = XCDR (tail))
    {
      fsevents_debug_count_pending_probe ();
      Lisp_Object pending = XCAR (tail);
      if (NILP (PENDING_ACTIVE (pending)))
	continue;
      any = true;
      *batch = Fcons (fsevents_resolve_pending_rename
		     (pending, file, current_actions, current_default_action),
		     *batch);
      PENDING_SET_INACTIVE (pending);
    }
  return any;
}

/* Flush every pending rename onto *BATCH, using CURRENT_FILE/
   CURRENT_ACTIONS when a later batch entry reuses the same pathname,
   then reset all four pending-tracking outputs to empty.  Visits the
   chronological list exactly once, emitting only ACTIVE entries;
   entries already resolved via fsevents_resolve_pending_bucket or the
   consecutive-pair check are skipped in place.  Callers at a
   root-changed or overflow boundary must flush (never leave the
   pending-by-path table stale) before any later concrete event in the
   same batch could otherwise resolve against it.  */
static void
fsevents_flush_pending_rename (Lisp_Object *pending_head,
			       Lisp_Object *pending_tail,
			       Lisp_Object *last_pending,
			       Lisp_Object *pending_by_path,
			       Lisp_Object *batch,
			       Lisp_Object current_file,
			       Lisp_Object current_actions,
			       Lisp_Object current_default_action)
{
  for (Lisp_Object tail = *pending_head; CONSP (tail); tail = XCDR (tail))
    {
      fsevents_debug_count_pending_probe ();
      Lisp_Object pending = XCAR (tail);
      if (NILP (PENDING_ACTIVE (pending)))
	continue;
      *batch = Fcons (fsevents_resolve_pending_rename (pending, current_file,
						       current_actions,
						       current_default_action),
		     *batch);
    }
  *pending_head = Qnil;
  *pending_tail = Qnil;
  *last_pending = Qnil;
  *pending_by_path = Qnil;
}

/* Generate a file notification event and store it in the keyboard
   buffer.  Return true if the watch was rewritten to stopped and
   should be disposed by the caller.  */
static bool
fsevents_generate_event (Lisp_Object watch_object, Lisp_Object actions,
			 Lisp_Object file, Lisp_Object file1)
{
  Lisp_Object flags, action, entry;
  struct input_event event;

  /* Symlink-leaf watches emulate inotify IN_DONT_FOLLOW semantics:
     the link entry is watched, not its target.  Only attribute
     changes are surfaced.  Delete/rename of the watched symlink leaf
     is marked as terminal so the FSEvents wrapper can remove the
     descriptor silently, while broader plain `stopped' conditions
     remain visible.  */
  bool symlink_watch = EQ (WATCH_TYPE (watch_object), Qsymlink);
  bool needs_dispose = false;

  /* Filter actions against the requested flags.  */
  flags = WATCH_FLAGS (watch_object);
  action = actions;
  do {
    if (NILP (action))
      break;
    entry = XCAR (action);
    if (EQ (entry, Qstopped))
      {
	action = XCDR (action);
	continue;
      }
    /* Symlink watches suppress everything except attrib.  When the
       link itself is deleted or renamed, preserve the terminal
       delete/rename marker so wrapper clients can distinguish that
       case from broader `stopped' conditions.  */
    if (symlink_watch && !EQ (entry, Qattrib))
      {
	if (fsevents_watch_root_p (watch_object, file)
	    && (EQ (entry, Qdelete) || EQ (entry, Qrename)))
	  {
	    actions = list2 (entry, Qstopped);
	    needs_dispose = true;
	    break;
	  }
	action = XCDR (action);
	actions = Fdelq (entry, actions);
	continue;
      }
    /* Root delete/rename must tear down the watch even when the
       caller did not request delete/rename explicitly.  File watches
       never get RootChanged for this, and shared directory watches
       may be served by a broader ancestor stream where RootChanged
       also never arrives for the logical watch root.  If the caller
       requested delete/rename, pass through the action so
       file-notify--handle-event sees the transition.  Otherwise,
       convert directly to stopped.  */
    if (fsevents_watch_root_p (watch_object, file)
	&& (EQ (entry, Qdelete) || EQ (entry, Qrename)))
      {
	needs_dispose = true;
	if (NILP (Fmember (entry, flags)))
	  {
	    /* Attribute-only watch: suppress the action itself but
	       emit stopped to tear down the watch.  */
	    actions = list1 (Qstopped);
	    break;
	  }
	/* Caller requested this action: let it through.  */
	action = XCDR (action);
      }
    else if (NILP (Fmember (entry, flags)))
      {
	action = XCDR (action);
	actions = Fdelq (entry, actions);
      }
    else
      action = XCDR (action);
  } while (1);

  /* Store it into the input event queue.  */
  if (! NILP (actions))
    {
      EVENT_INIT (event);
      event.kind = FILE_NOTIFY_EVENT;
      event.frame_or_window = Qnil;
      event.arg = list2 (Fcons (WATCH_DESC (watch_object),
				Fcons (actions,
				       NILP (file1)
				       ? list1 (file)
				       : list2 (file, file1))),
			 WATCH_CALLBACK (watch_object));
      kbd_buffer_store_event (&event);
    }
  return needs_dispose;
}


/* ================================================================
   FSEvents stream callback.  Fires on the GCD dispatch queue thread.

   MUST NOT touch Lisp objects.  Copies raw C data into a raw_batch
   and enqueues it for main-thread processing.  */

static void
fsevents_stream_callback (ConstFSEventStreamRef streamRef,
			  void *clientCallBackInfo,
			  size_t numEvents,
			  void *eventPaths,
			  const FSEventStreamEventFlags eventFlags[],
			  const FSEventStreamEventId eventIds[])
{
  int stream_id = (int) (intptr_t) clientCallBackInfo;
  char **paths = (char **) eventPaths;

  struct raw_batch *batch = malloc (sizeof *batch);
  if (!batch)
    return;

  batch->stream_id = stream_id;
  batch->num_events = numEvents;
  batch->events = malloc (numEvents * sizeof *batch->events);
  if (!batch->events)
    {
      free (batch);
      return;
    }

  for (size_t i = 0; i < numEvents; i++)
    {
      batch->events[i].path = strdup (paths[i]);
      batch->events[i].flags = eventFlags[i];
      /* Snapshot filesystem state now, while the callback is still
	 close to the actual event.  Main-thread processing may run
	 much later, by which time the path could have been recreated
	 or removed, breaking rename classification.  Only rename
	 candidates ever consult PATH_EXISTS (see
	 fsevents_one_sided_rename_action and the pending-rename
	 pairing logic), so restricting the lstat syscall to them
	 saves one stat(2) call per non-rename event without changing
	 observable behavior: PATH_EXISTS defaults to false, which is
	 what a non-rename entry's PATH_EXISTS was always effectively
	 unset to before this change, since nothing ever read it.  */
      batch->events[i].path_exists = false;
      if (eventFlags[i] & kFSEventStreamEventFlagItemRenamed)
	{
	  if (__atomic_load_n (&fsevents_debug_performance_counters_enabled,
			       __ATOMIC_ACQUIRE))
	    __atomic_fetch_add (&fsevents_debug_lstat_calls, 1,
				__ATOMIC_RELAXED);
	  struct stat st;
	  batch->events[i].path_exists = (lstat (paths[i], &st) == 0);
	}
    }

  raw_queue_push (batch);
}


/* ================================================================
   Main-thread batch processing.

   This contains all the rename-pairing logic that was previously in
   the stream callback but now operates on raw C data, converting to
   Lisp objects as needed.  Runs exclusively on the main thread.  */

static void
fsevents_process_raw_batch_for_watch (struct raw_batch *raw,
                                      Lisp_Object const *decoded_paths,
                                      Lisp_Object watch_obj)
{
  fsevents_debug_count_watch_dispatch ();

  int descriptor = XFIXNUM (WATCH_DESC (watch_obj));
  size_t numEvents = raw->num_events;
  struct raw_event *events = raw->events;
  Lisp_Object batch = Qnil;  /* Built in reverse.  */

  /* Chronological pending-rename list for this watch's dispatch of
     this batch, plus the O(1) append/lookup helpers above
     (fsevents_pending_append, fsevents_resolve_pending_bucket,
     fsevents_flush_pending_rename).  PENDING_TAIL is the last cons of
     PENDING_HEAD; LAST_PENDING is the most recently appended entry,
     the only candidate for the consecutive-index pair check;
     PENDING_BY_PATH indexes every still-pending entry by normalized
     path for O(1) same-path resolution.  */
  Lisp_Object pending_head = Qnil;
  Lisp_Object pending_tail = Qnil;
  Lisp_Object last_pending = Qnil;
  Lisp_Object pending_by_path = Qnil;

  Lisp_Object resolved_dir = WATCH_RESOLVED_DIR (watch_obj);
  Lisp_Object orig_dir = WATCH_DIR (watch_obj);

  for (size_t i = 0; i < numEvents; i++)
    {
      FSEventStreamEventFlags flags = events[i].flags;
      bool is_rename = false;
      /* DECODED_PATHS[i] was decoded once per batch by the caller;
	 only the per-watch namespace translation happens here.  */
      Lisp_Object file
	= fsevents_translate_path (decoded_paths[i], resolved_dir, orig_dir);
      Lisp_Object current_default_action = Qnil;
      bool path_exists = events[i].path_exists;

      Lisp_Object actions = fsevents_actions_from_flags (flags, &is_rename);

      if (is_rename)
	current_default_action = fsevents_one_sided_rename_action (path_exists);

      if (flags & kFSEventStreamEventFlagRootChanged)
	{
	  /* RootChanged is reported for the native stream root, not
	     necessarily for every logical watch sharing that stream.
	     Preserve the root's own final transition, but stop descendant
	     logical watches without forwarding the ancestor path.  */
	  if (fsevents_watch_root_p (watch_obj, file))
	    {
	      fsevents_flush_pending_rename (&pending_head, &pending_tail,
					     &last_pending, &pending_by_path,
					     &batch, file, actions,
					     current_default_action);
	      batch = Fcons (list3 (make_fixnum (descriptor),
				    nconc2 (actions, list1 (Qstopped)),
				    file),
			     batch);
	    }
	  else
	    {
	      fsevents_flush_pending_rename (&pending_head, &pending_tail,
					     &last_pending, &pending_by_path,
					     &batch, Qnil, Qnil, Qnil);
	      batch = Fcons (list3 (make_fixnum (descriptor),
				    list1 (Qstopped),
				    WATCH_FILE (watch_obj)),
			     batch);
	    }
	  break;
	}
      if (flags & kFSEventStreamEventFlagMustScanSubDirs)
	{
	  /* Some events in this batch were coalesced or dropped.
	     For file watches the overflow is irrelevant -- the file's
	     own events are still delivered individually.  For directory
	     watches whose root covers the overflow path, direct children
	     may have been coalesced, so emit a synthetic change to trigger
	     rescanning (e.g.
	     auto-revert-dired).  This mirrors inotify's IN_Q_OVERFLOW
	     behavior of reporting the overflow rather than swallowing it.
	     Deep descendant churn may cause a spurious rescan, but that
	     is the safe choice -- missing real changes is worse.  */
	  fsevents_flush_pending_rename (&pending_head, &pending_tail,
					 &last_pending, &pending_by_path,
					 &batch, file, actions,
					 current_default_action);
	  if (EQ (WATCH_TYPE (watch_obj), Qt)
	      && fsevents_path_within_watch_root_p (watch_obj, file))
	    {
	      /* Emit `created' on the watched directory itself.
		 This is the action that auto-revert-notify-handler
		 uses to trigger a dired rescan (it ignores
		 changed/attribute-changed for directory buffers).  */
	      batch = Fcons (list3 (make_fixnum (descriptor),
				    list1 (Qcreate),
				    WATCH_FILE (watch_obj)),
			     batch);
	    }
	}

      if (NILP (actions))
	continue;

      if (is_rename)
	{
	  /* First, resolve any pending entry sharing FILE's normalized
	     path in O(1) via the hash index.  This covers same-path
	     pending resolution, including same-path/trailing-slash
	     equivalence.  This only settles OLDER entries; it never
	     consumes the current event itself, which independently
	     still needs to become pending below unless the
	     consecutive-index pairing check consumes it instead.  */
	  fsevents_resolve_pending_bucket (pending_by_path, file, actions,
					   current_default_action, &batch);

	  /* Otherwise, FSEvents guarantees rename pairs are consecutive
	     batch entries, so the only other possible pair partner is
	     the immediately preceding pending entry.  The pending must
	     be a source (fallback == delete, absent on disk) and the
	     current must be a destination (path_exists == true) to
	     reject two one-sided renames of the same polarity (bulk
	     move-outs or bulk move-ins).  Note: FSEvents does not
	     provide a rename cookie, so a move-out at index i followed
	     by an unrelated move-in at index i+1 in the same batch is
	     indistinguishable from a real in-tree rename.  This is a
	     known limitation accepted for the common-case correctness
	     of in-tree rename detection.  Rename chains (a -> b -> c)
	     where the midpoint b is absent degrade to one-sided
	     events, which is also documented.  If LAST_PENDING was
	     just resolved above (same path as FILE), its ACTIVE flag
	     is already nil, so the guard below correctly skips it.  */
	  bool paired = false;
	  if (!NILP (last_pending))
	    {
	      fsevents_debug_count_pending_probe ();
	      /* Load-bearing invariant: fsevents_resolve_pending_bucket
		 above already ran for FILE's normalized path this
		 iteration, so if LAST_PENDING shares that path its
		 ACTIVE flag is guaranteed nil here.  If a future edit
		 reorders these two steps this assertion will catch it
		 before it silently double-pairs a resolved entry.  */
	      eassert (NILP (PENDING_ACTIVE (last_pending))
		       || !fsevents_same_path_p (PENDING_FILE (last_pending),
						 file));
	      if (!NILP (PENDING_ACTIVE (last_pending))
		  && PENDING_BATCH_IDX (last_pending) == (ptrdiff_t) i - 1
		  && EQ (PENDING_ACTION (last_pending), Qdelete)
		  && path_exists)
		{
		  Lisp_Object old_file = PENDING_FILE (last_pending);

		  if (fsevents_rename_pair_relevant_p (descriptor, old_file,
						       file))
		    {
		      batch = Fcons (list4 (make_fixnum (descriptor),
					    list1 (Qrename), old_file, file),
				     batch);
		      PENDING_SET_INACTIVE (last_pending);
		      paired = true;
		    }
		  else
		    {
		      Lisp_Object boundary_entry
			= fsevents_cross_boundary_rename_entry (descriptor,
								old_file, file);
		      if (!NILP (boundary_entry))
			{
			  batch = Fcons (boundary_entry, batch);
			  PENDING_SET_INACTIVE (last_pending);
			  paired = true;
			}
		    }
		}
	    }

	  Lisp_Object other_actions = Fdelq (Qrename, actions);
	  if (paired)
	    {
	      if (!NILP (other_actions))
		batch = Fcons (list3 (make_fixnum (descriptor),
				      other_actions, file),
			       batch);
	      continue;
	    }

	  /* Not paired: save as pending rename, waiting for a later
	     batch entry to resolve or pair it.  */
	  Lisp_Object current_pending
	    = fsevents_make_pending_rename (descriptor, file, i, path_exists);
	  fsevents_pending_append (&pending_head, &pending_tail, &last_pending,
				   &pending_by_path, current_pending);
	  /* Enqueue non-rename actions if any.  */
	  if (!NILP (other_actions))
	    batch = Fcons (list3 (make_fixnum (descriptor),
				  other_actions, file),
			   batch);
	}
      else
	{
	  /* Before emitting this non-rename event, resolve any pending
	     one-sided renames on the same path.  Without this, a
	     sequence like "rename /watched/a /tmp/out, create /watched/a"
	     would miss the delete for a, because the pending rename's
	     fallback action was computed from the post-batch filesystem
	     state where a already exists again.  */
	  fsevents_resolve_pending_bucket (pending_by_path, file, actions,
					   Qnil, &batch);
	  batch = Fcons (list3 (make_fixnum (descriptor), actions, file),
			 batch);
	}
    }

  /* Flush any unpaired pending rename from this batch.  */
  if (!NILP (pending_head))
    fsevents_flush_pending_rename (&pending_head, &pending_tail, &last_pending,
				   &pending_by_path, &batch, Qnil, Qnil, Qnil);

  /* Reverse the batch to restore chronological order, then dispatch
     each event.  */
  if (!NILP (batch))
    {
      batch = Fnreverse (batch);

      while (CONSP (batch))
	{
	  Lisp_Object entry = XCAR (batch);
	  batch = XCDR (batch);

	  int desc = XFIXNUM (XCAR (entry));
	  Lisp_Object actions = XCAR (XCDR (entry));
	  Lisp_Object file = XCAR (XCDR (XCDR (entry)));
	  Lisp_Object file1 = Qnil;
	  if (!NILP (XCDR (XCDR (XCDR (entry)))))
	    file1 = XCAR (XCDR (XCDR (XCDR (entry))));

	  Lisp_Object watch_object = fsevents_find_watch (desc);
	  if (!CONSP (watch_object))
	    continue;

	  if (!NILP (Fmember (Qstopped, actions)))
	    {
	      fsevents_dispose_watch (watch_object);
	      fsevents_generate_event (watch_object, actions, file, file1);
	      continue;
	    }

	  /* Filter out events for paths outside the watched scope.
	     FSEvents reports the entire subtree; we restrict to the
	     watched directory level (or the exact watched file).  */
	  bool relevant = fsevents_path_relevant_p (watch_object, file);
	  if (!relevant && !NILP (file1) && !NILP (Fmember (Qrename, actions)))
	    {
	      relevant = fsevents_path_relevant_p (watch_object, file1);
	    }
	  if (!relevant)
	    continue;

	  if (fsevents_generate_event (watch_object, actions, file, file1))
	    fsevents_dispose_watch (watch_object);
	}
    }
}

static void
fsevents_process_raw_batch (struct raw_batch *raw)
{
  Lisp_Object stream_entry = fsevents_find_stream (raw->stream_id);
  if (!CONSP (stream_entry))
    return;

  fsevents_debug_count_batch_prepare ();

  /* Decode each raw physical path exactly once per batch, then hand
     every logical watch sharing this stream the same immutable
     array; only the per-watch namespace translation
     (fsevents_translate_path) still runs once per watch per event.
     No allocation is needed for an empty batch: the callee's
     zero-iteration loop never dereferences DECODED_PATHS.  */
  Lisp_Object *decoded_paths = NULL;
  USE_SAFE_ALLOCA;
  if (raw->num_events)
    {
      SAFE_ALLOCA_LISP (decoded_paths, raw->num_events);
      for (size_t i = 0; i < raw->num_events; i++)
	decoded_paths[i] = DECODE_FILE (build_unibyte_string (raw->events[i].path));
    }

  if (FIXNUMP (STREAM_RETIRED_TO (stream_entry)))
    for (Lisp_Object tail = STREAM_RETIRED_WATCHES (stream_entry);
         CONSP (tail); tail = XCDR (tail))
      {
        Lisp_Object watch_obj = fsevents_find_watch (XFIXNUM (XCAR (tail)));
        if (CONSP (watch_obj))
          fsevents_process_raw_batch_for_watch (raw, decoded_paths, watch_obj);
      }
  else
    for (Lisp_Object tail = watch_list; CONSP (tail); tail = XCDR (tail))
      {
        Lisp_Object watch_obj = XCAR (tail);
        if (XFIXNUM (WATCH_STREAM_ID (watch_obj)) == raw->stream_id)
          fsevents_process_raw_batch_for_watch (raw, decoded_paths, watch_obj);
      }

  SAFE_FREE ();
}


/* ================================================================
   Self-pipe and read callback.  */

/* Read callback registered via add_read_fd on the self-pipe read end.
   Drains the pipe and processes all queued raw batches.  */
static void
fsevents_read_callback (int fd, void *data)
{
  /* Consume one readiness chunk, then process queued batches.  Leaving
     surplus bytes for a later callback prevents sustained activity from
     starving batch handling on the main thread.  */
  char buf[64];
  (void) read (fd, buf, sizeof buf);

  struct raw_batch *head = raw_queue_drain ();
  if (fsevents_debug_inject_batch_during_read)
    {
      fsevents_debug_inject_batch_during_read = false;
      raw_queue_push_without_wake
        (raw_batch_make_empty (fsevents_debug_inject_stream_id));
    }
  while (head)
    {
      struct raw_batch *next = head->next;
      fsevents_process_raw_batch (head);
      raw_batch_free (head);
      head = next;
    }

  raw_queue_rearm_if_needed ();
  fsevents_reap_retired_streams_if_idle ();
}

/* Set up the self-pipe (non-blocking) and register with the event loop.  */
static void
fsevents_ensure_pipe (void)
{
  if (fsevents_pipe[0] >= 0)
    return;

  if (emacs_pipe (fsevents_pipe) != 0)
    report_file_notify_error ("Cannot create pipe for fsevents", Qnil);

  /* Make both ends non-blocking.  */
  fcntl (fsevents_pipe[0], F_SETFL, O_NONBLOCK);
  fcntl (fsevents_pipe[1], F_SETFL, O_NONBLOCK);

  add_read_fd (fsevents_pipe[0], fsevents_read_callback, NULL);
}

/* Tear down the self-pipe when no watches remain.
   Acquires raw_queue_mutex to ensure no concurrent pipe write from
   the GCD dispatch queue thread can race with the close.  */
static void
fsevents_close_pipe (void)
{
  if (fsevents_pipe[0] < 0)
    return;

  delete_read_fd (fsevents_pipe[0]);

  /* Snapshot and invalidate under the lock so the callback thread
     sees -1 before we close the actual file descriptors.  Also
     detach any pending raw batches under the same lock so they
     can be freed after unlocking.  */
  pthread_mutex_lock (&raw_queue_mutex);
  int rd = fsevents_pipe[0];
  int wr = fsevents_pipe[1];
  fsevents_pipe[0] = -1;
  fsevents_pipe[1] = -1;
  struct raw_batch *stale = raw_queue_head;
  raw_queue_head = NULL;
  raw_queue_tail = NULL;
  pthread_mutex_unlock (&raw_queue_mutex);

  /* Free any batches that were queued but never processed.  */
  while (stale)
    {
      struct raw_batch *next = stale->next;
      raw_batch_free (stale);
      stale = next;
    }

  /* Clearing the pending queue above can make retired stream aliases
     collectible even though no read callback will run anymore.  */
  fsevents_reap_retired_streams_if_idle ();

  emacs_close (rd);
  emacs_close (wr);
}


/* ================================================================
   Lisp interface.  */

DEFUN ("fsevents-add-watch", Ffsevents_add_watch, Sfsevents_add_watch,
       3, 3, 0,
       doc: /* Add a watch for filesystem events pertaining to FILE.

This arranges for filesystem events pertaining to FILE to be reported
to Emacs.  Use `fsevents-rm-watch' to cancel the watch.

Returned value is a descriptor for the added watch.  If the file cannot be
watched for some reason, this function signals a `file-notify-error' error.

FLAGS is a list of events to be watched for.  It can include the
following symbols:

  `create' -- FILE was created
  `delete' -- FILE was deleted
  `write'  -- FILE has changed
  `attrib' -- a FILE attribute was changed
  `rename' -- FILE was moved to FILE1

When any event happens, Emacs will call the CALLBACK function passing
it a single argument EVENT, which is of the form

  (DESCRIPTOR ACTIONS FILE [FILE1])

DESCRIPTOR is the same object as the one returned by this function.
ACTIONS is a list of event symbols.  FILE is the name of the file
whose event is being reported.  FILE1 is non-nil for rename
events where the file was renamed to FILE1.  */)
  (Lisp_Object file, Lisp_Object flags, Lisp_Object callback)
{
  Lisp_Object dir, watch_type, resolved_dir;

  CHECK_STRING (file);
  file = Fexpand_file_name (file, Qnil);
  file = Fdirectory_file_name (file);

  /* Normalize directory arguments to their slashless form before all
     watch classification.  FSEvents reports root paths without a
     trailing slash, and Ffile_symlink_p on macOS follows a
     slash-suffixed symlinked directory instead of probing the link
     itself.  This keeps FILE and the later callback paths in the same
     namespace, so ".../dir" and ".../dir/" behave identically.

     Detect symlinks without following them.  When the watched path
     IS a symlink (regardless of whether it points to a file or
     directory), treat it as a file watch on its parent directory.
     This matches inotify IN_DONT_FOLLOW semantics: the link itself
     is watched, not its target.  Ffile_symlink_p uses lstat and
     returns the target string for symlinks, nil otherwise.

     Symlink watches suppress all events except attribute changes
     (file-notify-test11-symlinks: writing, deletion, and
     set-file-times without nofollow all produce no events).  */
  if (!NILP (Ffile_symlink_p (file)))
    {
      watch_type = Qsymlink;
      dir = Ffile_name_directory (file);
      if (NILP (dir) || NILP (Ffile_directory_p (dir)))
	report_file_error ("Directory does not exist",
			   NILP (dir) ? file : dir);
    }
  else if (!NILP (Ffile_directory_p (file)))
    {
      watch_type = Qt;
      dir = Ffile_name_as_directory (file);
    }
  else
    {
      watch_type = Qnil;
      dir = Ffile_name_directory (file);
      if (NILP (Ffile_directory_p (dir)))
	report_file_error ("Directory does not exist", dir);
    }

  CHECK_LIST (flags);

  if (! FUNCTIONP (callback))
    wrong_type_argument (Qinvalid_function, callback);

  /* Resolve symlinks in the directory path for FSEvents.  FSEvents
     does not traverse symlinks mid-path and fails with ENOTDIR
     (e.g. ~/projects is a symlink to ~/Desktop/projects).

     The resolved path is used for the FSEventStream and for
     translating physical event paths back to the caller's original
     namespace.  The original DIR and FILE are preserved in the watch
     object and used for event reporting, so callbacks see the path
     the caller asked to watch.  */
  resolved_dir = calln (Qfile_truename, Ffile_name_as_directory (dir));
  if (!STRINGP (resolved_dir))
    resolved_dir = dir;
  resolved_dir = Ffile_name_as_directory (resolved_dir);

  /* Ensure the dispatch queue and self-pipe are set up.  */
  fsevents_ensure_queue ();
  fsevents_ensure_pipe ();

  Lisp_Object stream_root = fsevents_choose_stream_root (resolved_dir);

  /* Allocate a descriptor.  */
  int descriptor = next_desc++;
  Lisp_Object watch_descriptor = make_fixnum (descriptor);
  Lisp_Object stream_entry = fsevents_find_covering_stream (stream_root);
  if (CONSP (stream_entry))
    XSETCAR (XCDR (XCDR (XCDR (stream_entry))),
             make_fixnum (XFIXNUM (STREAM_REFCOUNT (stream_entry)) + 1));
  else
    {
      stream_entry = fsevents_make_stream (stream_root);
      fsevents_retarget_descendant_streams (stream_entry, stream_root);
    }

  /* Store the logical watch.
     Format: (DESC FILE DIR TYPE FLAGS CALLBACK STREAM-ID RESOLVED_DIR)
     FILE and DIR use the caller's original paths; RESOLVED_DIR holds
     the physical path for event path translation.  TYPE is Qt
     (directory), Qnil (file), or Qsymlink (symlink leaf).  */
  Lisp_Object watch_object
    = Fcons (watch_descriptor,
	     Fcons (file,
		    Fcons (dir,
			   Fcons (watch_type,
				  Fcons (flags,
					 Fcons (callback,
						list2 (STREAM_ID (stream_entry),
						      resolved_dir)))))));
  watch_list = Fcons (watch_object, watch_list);

  return watch_descriptor;
}

DEFUN ("fsevents-rm-watch", Ffsevents_rm_watch, Sfsevents_rm_watch, 1, 1, 0,
       doc: /* Remove an existing WATCH-DESCRIPTOR.

WATCH-DESCRIPTOR should be an object returned by `fsevents-add-watch'.  */)
  (Lisp_Object watch_descriptor)
{
  Lisp_Object watch_object = assq_no_quit (watch_descriptor, watch_list);

  if (! CONSP (watch_object))
    xsignal2 (Qfile_notify_error, build_string ("Not a watch descriptor"),
	      watch_descriptor);

  fsevents_dispose_watch (watch_object);

  return Qt;
}

DEFUN ("fsevents-valid-p", Ffsevents_valid_p, Sfsevents_valid_p, 1, 1, 0,
       doc: /* Check a watch specified by its WATCH-DESCRIPTOR.

WATCH-DESCRIPTOR should be an object returned by `fsevents-add-watch'.

A watch can become invalid if the file or directory it watches is
deleted, or if the watcher thread exits abnormally for any other
reason.  Removing the watch by calling `fsevents-rm-watch' also makes it
invalid.  */)
  (Lisp_Object watch_descriptor)
{
  return NILP (assq_no_quit (watch_descriptor, watch_list)) ? Qnil : Qt;
}

DEFUN ("fsevents--debug-stream-count", Ffsevents_debug_stream_count,
       Sfsevents_debug_stream_count, 0, 0, 0,
       doc: /* Return the number of active native FSEvents streams.  */)
  (void)
{
  ptrdiff_t count = 0;
  for (Lisp_Object tail = stream_list; CONSP (tail); tail = XCDR (tail))
    if (fsevents_stream_active_p (XCAR (tail)))
      count++;

  return make_fixnum (count);
}

DEFUN ("fsevents--debug-enqueue-empty-batch",
       Ffsevents_debug_enqueue_empty_batch,
       Sfsevents_debug_enqueue_empty_batch, 1, 1, 0,
       doc: /* Enqueue an empty raw batch for test instrumentation.  */)
  (Lisp_Object stream_id)
{
  CHECK_FIXNUM (stream_id);
  fsevents_ensure_pipe ();
  raw_queue_push (raw_batch_make_empty (XFIXNUM (stream_id)));
  return Qnil;
}

DEFUN ("fsevents--debug-inject-empty-batch-during-read",
       Ffsevents_debug_inject_empty_batch_during_read,
       Sfsevents_debug_inject_empty_batch_during_read, 1, 1, 0,
       doc: /* Inject an empty raw batch without a wake byte during read.  */)
  (Lisp_Object stream_id)
{
  CHECK_FIXNUM (stream_id);
  fsevents_debug_inject_batch_during_read = true;
  fsevents_debug_inject_stream_id = XFIXNUM (stream_id);
  return Qnil;
}

DEFUN ("fsevents--debug-watch-stream-id", Ffsevents_debug_watch_stream_id,
       Sfsevents_debug_watch_stream_id, 1, 1, 0,
       doc: /* Return the native stream id serving WATCH-DESCRIPTOR.  */)
  (Lisp_Object watch_descriptor)
{
  CHECK_FIXNUM (watch_descriptor);
  Lisp_Object watch = fsevents_find_watch (XFIXNUM (watch_descriptor));
  if (!CONSP (watch))
    xsignal2 (Qfile_notify_error, build_string ("Not a watch descriptor"),
              watch_descriptor);
  return WATCH_STREAM_ID (watch);
}

DEFUN ("fsevents--debug-enqueue-overflow-batch",
       Ffsevents_debug_enqueue_overflow_batch,
       Sfsevents_debug_enqueue_overflow_batch, 2, 2, 0,
       doc: /* Enqueue a synthetic MustScanSubDirs batch for tests.  */)
  (Lisp_Object stream_id, Lisp_Object path)
{
  CHECK_FIXNUM (stream_id);
  CHECK_STRING (path);
  fsevents_ensure_pipe ();

  struct raw_batch *batch = malloc (sizeof *batch);
  if (!batch)
    memory_full (SIZE_MAX);

  batch->stream_id = XFIXNUM (stream_id);
  batch->num_events = 1;
  batch->events = malloc (sizeof *batch->events);
  if (!batch->events)
    {
      free (batch);
      memory_full (SIZE_MAX);
    }

  Lisp_Object encoded = ENCODE_FILE (path);
  batch->events[0].path = strdup (SSDATA (encoded));
  if (!batch->events[0].path)
    {
      free (batch->events);
      free (batch);
      memory_full (SIZE_MAX);
    }
  batch->events[0].flags = kFSEventStreamEventFlagMustScanSubDirs;
  batch->events[0].path_exists = true;
  raw_queue_push (batch);
  return Qnil;
}

DEFUN ("fsevents--debug-enqueue-overflow-write-batch",
       Ffsevents_debug_enqueue_overflow_write_batch,
       Sfsevents_debug_enqueue_overflow_write_batch, 3, 3, 0,
       doc: /* Enqueue MustScanSubDirs followed by ItemModified for tests.  */)
  (Lisp_Object stream_id, Lisp_Object overflow_path, Lisp_Object file_path)
{
  CHECK_FIXNUM (stream_id);
  CHECK_STRING (overflow_path);
  CHECK_STRING (file_path);
  fsevents_ensure_pipe ();

  struct raw_batch *batch = malloc (sizeof *batch);
  if (!batch)
    memory_full (SIZE_MAX);

  batch->stream_id = XFIXNUM (stream_id);
  batch->num_events = 2;
  batch->events = malloc (sizeof *batch->events * batch->num_events);
  if (!batch->events)
    {
      free (batch);
      memory_full (SIZE_MAX);
    }

  Lisp_Object encoded_overflow = ENCODE_FILE (overflow_path);
  batch->events[0].path = strdup (SSDATA (encoded_overflow));
  if (!batch->events[0].path)
    {
      free (batch->events);
      free (batch);
      memory_full (SIZE_MAX);
    }
  batch->events[0].flags = kFSEventStreamEventFlagMustScanSubDirs;
  batch->events[0].path_exists = true;

  Lisp_Object encoded_file = ENCODE_FILE (file_path);
  batch->events[1].path = strdup (SSDATA (encoded_file));
  if (!batch->events[1].path)
    {
      free (batch->events[0].path);
      free (batch->events);
      free (batch);
      memory_full (SIZE_MAX);
    }
  batch->events[1].flags = kFSEventStreamEventFlagItemModified;
  batch->events[1].path_exists = true;

  raw_queue_push (batch);
  return Qnil;
}

DEFUN ("fsevents--debug-enqueue-delete-batch",
       Ffsevents_debug_enqueue_delete_batch,
       Sfsevents_debug_enqueue_delete_batch, 2, 2, 0,
       doc: /* Enqueue a synthetic ItemRemoved batch for tests.  */)
  (Lisp_Object stream_id, Lisp_Object path)
{
  CHECK_FIXNUM (stream_id);
  CHECK_STRING (path);
  fsevents_ensure_pipe ();

  struct raw_batch *batch = malloc (sizeof *batch);
  if (!batch)
    memory_full (SIZE_MAX);

  batch->stream_id = XFIXNUM (stream_id);
  batch->num_events = 1;
  batch->events = malloc (sizeof *batch->events);
  if (!batch->events)
    {
      free (batch);
      memory_full (SIZE_MAX);
    }

  Lisp_Object encoded = ENCODE_FILE (path);
  batch->events[0].path = strdup (SSDATA (encoded));
  if (!batch->events[0].path)
    {
      free (batch->events);
      free (batch);
      memory_full (SIZE_MAX);
    }
  batch->events[0].flags = kFSEventStreamEventFlagItemRemoved;
  batch->events[0].path_exists = false;
  raw_queue_push (batch);
  return Qnil;
}

DEFUN ("fsevents--debug-enqueue-root-changed-batch",
       Ffsevents_debug_enqueue_root_changed_batch,
       Sfsevents_debug_enqueue_root_changed_batch, 2, 2, 0,
       doc: /* Enqueue a synthetic RootChanged|ItemRenamed batch for tests.  */)
  (Lisp_Object stream_id, Lisp_Object path)
{
  CHECK_FIXNUM (stream_id);
  CHECK_STRING (path);
  fsevents_ensure_pipe ();

  struct raw_batch *batch = malloc (sizeof *batch);
  if (!batch)
    memory_full (SIZE_MAX);

  batch->stream_id = XFIXNUM (stream_id);
  batch->num_events = 1;
  batch->events = malloc (sizeof *batch->events);
  if (!batch->events)
    {
      free (batch);
      memory_full (SIZE_MAX);
    }

  Lisp_Object encoded = ENCODE_FILE (path);
  batch->events[0].path = strdup (SSDATA (encoded));
  if (!batch->events[0].path)
    {
      free (batch->events);
      free (batch);
      memory_full (SIZE_MAX);
    }
  batch->events[0].flags = (kFSEventStreamEventFlagRootChanged
			    | kFSEventStreamEventFlagItemRenamed);
  batch->events[0].path_exists = false;
  raw_queue_push (batch);
  return Qnil;
}

DEFUN ("fsevents--debug-write-wake-bytes", Ffsevents_debug_write_wake_bytes,
       Sfsevents_debug_write_wake_bytes, 1, 1, 0,
       doc: /* Write COUNT bytes to the FSEvents wake pipe for tests.  */)
  (Lisp_Object count)
{
  CHECK_FIXNAT (count);
  fsevents_ensure_pipe ();

  ptrdiff_t remaining = XFIXNAT (count);
  char buf[64];
  memset (buf, 0, sizeof buf);

  while (remaining > 0)
    {
      ssize_t written = write (fsevents_pipe[1], buf,
                               remaining < (ptrdiff_t) sizeof buf
                               ? remaining : (ptrdiff_t) sizeof buf);
      if (written <= 0)
        break;
      remaining -= written;
    }

  return make_fixnum (XFIXNAT (count) - remaining);
}

DEFUN ("fsevents--debug-drain-wake-bytes", Ffsevents_debug_drain_wake_bytes,
       Sfsevents_debug_drain_wake_bytes, 0, 0, 0,
       doc: /* Drain and count pending wake bytes from the FSEvents pipe.  */)
  (void)
{
  ptrdiff_t count = 0;
  char buf[64];
  ssize_t nread;

  while (fsevents_pipe[0] >= 0
         && (nread = read (fsevents_pipe[0], buf, sizeof buf)) > 0)
    count += nread;

  return make_fixnum (count);
}

DEFUN ("fsevents--debug-handle-pipe-ready", Ffsevents_debug_handle_pipe_ready,
       Sfsevents_debug_handle_pipe_ready, 0, 0, 0,
       doc: /* Invoke the FSEvents self-pipe read callback for tests.  */)
  (void)
{
  if (fsevents_pipe[0] >= 0)
    fsevents_read_callback (fsevents_pipe[0], NULL);
  return Qnil;
}

DEFUN ("fsevents--debug-reset-performance-counters",
       Ffsevents_debug_reset_performance_counters,
       Sfsevents_debug_reset_performance_counters, 0, 0, 0,
       doc: /* Reset FSEvents performance counters to zero and enable them.

Synchronizes the GCD callback queue first so that setup callbacks
already in flight cannot race past the reset.  Counting stays enabled
until Emacs exits; only the counter values are meant to be
test-local.  */)
  (void)
{
  fsevents_sync_callback_queue ();
  fsevents_debug_batch_prepares = 0;
  fsevents_debug_watch_dispatches = 0;
  fsevents_debug_pending_probes = 0;
  __atomic_store_n (&fsevents_debug_lstat_calls, 0, __ATOMIC_RELEASE);
  __atomic_store_n (&fsevents_debug_performance_counters_enabled, true,
                    __ATOMIC_RELEASE);
  return Qnil;
}

DEFUN ("fsevents--debug-performance-counters",
       Ffsevents_debug_performance_counters,
       Sfsevents_debug_performance_counters, 0, 0, 0,
       doc: /* Return (BATCH-PREPARES WATCH-DISPATCHES PENDING-PROBES LSTAT-CALLS).  */)
  (void)
{
  uintmax_t lstat_calls
    = __atomic_load_n (&fsevents_debug_lstat_calls, __ATOMIC_ACQUIRE);
  return list4 (make_uint (fsevents_debug_batch_prepares),
                make_uint (fsevents_debug_watch_dispatches),
                make_uint (fsevents_debug_pending_probes),
                make_uint (lstat_calls));
}

DEFUN ("fsevents--debug-enqueue-rename-batch",
       Ffsevents_debug_enqueue_rename_batch,
       Sfsevents_debug_enqueue_rename_batch, 2, 2, 0,
       doc: /* Enqueue a synthetic all-ItemRenamed batch for tests.

STREAM-ID is the native stream to attribute the batch to.  EVENTS is
a list of (PATH EXISTS) entries; each becomes one rename-flagged raw
event, with PATH_EXISTS set from non-nil EXISTS.  */)
  (Lisp_Object stream_id, Lisp_Object events)
{
  CHECK_FIXNUM (stream_id);
  CHECK_LIST (events);

  ptrdiff_t num_events = 0;
  for (Lisp_Object tail = events; CONSP (tail); tail = XCDR (tail))
    {
      Lisp_Object entry = XCAR (tail);
      if (!CONSP (entry) || !STRINGP (XCAR (entry)) || !CONSP (XCDR (entry))
          || !NILP (XCDR (XCDR (entry))))
        xsignal2 (Qfile_notify_error,
                  build_string ("Malformed rename batch entry; expected (PATH EXISTS)"),
                  entry);
      num_events++;
    }

  fsevents_ensure_pipe ();

  struct raw_batch *batch = malloc (sizeof *batch);
  if (!batch)
    memory_full (SIZE_MAX);
  batch->stream_id = XFIXNUM (stream_id);
  batch->num_events = num_events;
  batch->events
    = num_events ? malloc (sizeof *batch->events * num_events) : NULL;
  if (num_events && !batch->events)
    {
      free (batch);
      memory_full (SIZE_MAX);
    }

  ptrdiff_t i = 0;
  for (Lisp_Object tail = events; CONSP (tail); tail = XCDR (tail), i++)
    {
      Lisp_Object entry = XCAR (tail);
      Lisp_Object path = XCAR (entry);
      Lisp_Object exists = XCAR (XCDR (entry));
      Lisp_Object encoded = ENCODE_FILE (path);
      char *copy = strdup (SSDATA (encoded));
      if (!copy)
        {
          for (ptrdiff_t j = 0; j < i; j++)
            free (batch->events[j].path);
          free (batch->events);
          free (batch);
          memory_full (SIZE_MAX);
        }
      batch->events[i].path = copy;
      batch->events[i].flags = kFSEventStreamEventFlagItemRenamed;
      batch->events[i].path_exists = !NILP (exists);
    }

  raw_queue_push (batch);
  return Qnil;
}


void
globals_of_fsevents (void)
{
  watch_list = Qnil;
  stream_list = Qnil;
  next_desc = 0;
  next_stream_id = 0;
  fsevents_debug_inject_batch_during_read = false;
  fsevents_debug_inject_stream_id = -1;
  fsevents_debug_performance_counters_enabled = false;
  fsevents_debug_batch_prepares = 0;
  fsevents_debug_watch_dispatches = 0;
  fsevents_debug_pending_probes = 0;
  fsevents_debug_lstat_calls = 0;
}

void
syms_of_fsevents (void)
{
  defsubr (&Sfsevents_add_watch);
  defsubr (&Sfsevents_rm_watch);
  defsubr (&Sfsevents_valid_p);
  defsubr (&Sfsevents_debug_stream_count);
  defsubr (&Sfsevents_debug_enqueue_empty_batch);
  defsubr (&Sfsevents_debug_inject_empty_batch_during_read);
  defsubr (&Sfsevents_debug_watch_stream_id);
  defsubr (&Sfsevents_debug_enqueue_overflow_batch);
  defsubr (&Sfsevents_debug_enqueue_overflow_write_batch);
  defsubr (&Sfsevents_debug_enqueue_delete_batch);
  defsubr (&Sfsevents_debug_enqueue_root_changed_batch);
  defsubr (&Sfsevents_debug_write_wake_bytes);
  defsubr (&Sfsevents_debug_drain_wake_bytes);
  defsubr (&Sfsevents_debug_handle_pipe_ready);
  defsubr (&Sfsevents_debug_reset_performance_counters);
  defsubr (&Sfsevents_debug_performance_counters);
  defsubr (&Sfsevents_debug_enqueue_rename_batch);

  /* Event types.  */
  DEFSYM (Qcreate, "create");
  DEFSYM (Qdelete, "delete");
  DEFSYM (Qwrite, "write");
  DEFSYM (Qattrib, "attrib");
  DEFSYM (Qrename, "rename");
  DEFSYM (Qstopped, "stopped");

  /* Watch types.  */
  DEFSYM (Qsymlink, "symlink");

  staticpro (&watch_list);
  staticpro (&stream_list);

  Fprovide (intern_c_string ("fsevents"), Qnil);
}
