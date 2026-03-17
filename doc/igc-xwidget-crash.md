# IGC/MPS xwidget crash analysis

## Summary

Emacs built with IGC (incremental/generational GC via MPS) crashes when
using xwidget-webkit on both macOS (NS) and Linux (GTK) backends.  The
crash manifests as SIGABRT inside `print_object` when attempting to print
an xwidget event, due to memory corruption caused by MPS moving xwidget
structs that are referenced by raw C pointers outside MPS-traced memory.

## Crash signature

```
Exception Type:    EXC_BAD_ACCESS (SIGABRT)
Exception Subtype: KERN_INVALID_ADDRESS at 0x656c65447265676d
                   -> possible pointer authentication failure

Thread 0 Crashed:
0  libsystem_kernel.dylib    __pthread_kill
1  libsystem_pthread.dylib   pthread_kill
2  libsystem_c.dylib         raise
3  emacs                     terminate_due_to_signal
4  emacs                     print_object
5  emacs                     Fprin1_to_string
6  emacs                     Ffuncall
7  xwidget-*.eln             xwidget_log
```

The address `0x656c65447265676d` decodes to the ASCII string
"mergeDelete" (a WebKit internal editing command name), confirming that
the xwidget struct's memory was reused by WebKit after MPS relocated it.

## Root cause

### Object allocation

Xwidgets are allocated as pseudovectors via `ALLOCATE_PSEUDOVECTOR` in
`src/xwidget.c:82`:

```c
static struct xwidget *
allocate_xwidget (void)
{
  return ALLOCATE_PSEUDOVECTOR (struct xwidget, script_callbacks,
                                PVEC_XWIDGET);
}
```

Under IGC, `igc_alloc_pseudovector` in `src/igc.c` dispatches this to
`alloc(size, IGC_OBJ_VECTOR)`, which allocates from a **movable** MPS
pool.  MPS is free to relocate these objects during garbage collection.

### External raw pointers

Both toolkit backends store raw `struct xwidget *` pointers in memory
that MPS cannot trace:

#### NS/macOS backend (`src/nsxwidget.m`)

The Objective-C `XwWebView` class holds a raw pointer as a property:

```objc
@interface XwWebView : WKWebView
@property struct xwidget *xw;
@end
```

WebKit delegate callbacks dereference this pointer directly:

```objc
- (void)webView:(WKWebView *)webView
didStartProvisionalNavigation:(WKNavigation *)navigation
{
  if (EQ (Fbuffer_live_p (self.xw->buffer), Qt))
    store_xwidget_event_string (self.xw, "load-changed",
                                "load-started");
}
```

The ObjC heap is not scanned by MPS.

#### GTK backend (`src/xwidget.c`)

Raw pointers are stashed in GObject user data:

```c
g_object_set_data (G_OBJECT (xw->widget_osr), XG_XWIDGET, xw);
g_object_set_data (G_OBJECT (xw->widgetwindow_osr), XG_XWIDGET, xw);
```

GTK signal handlers retrieve them via `g_object_get_data`:

```c
static void
webkit_view_load_changed_cb (WebKitWebView *webkitwebview,
                             WebKitLoadEvent load_event,
                             gpointer data)
{
  struct xwidget *xw = g_object_get_data (G_OBJECT (webkitwebview),
                                          XG_XWIDGET);
  // ... dereferences xw
}
```

GObject's internal data store is not scanned by MPS.

### The crash sequence

1. User opens an xwidget-webkit buffer (e.g. `xwidget-webkit-browse-url`)
2. An `xwidget` struct is allocated in MPS's movable pool
3. A raw pointer to it is stored in ObjC property / GObject user data
4. WebKit starts loading the page, firing navigation callbacks
5. MPS runs a GC cycle and **moves** the xwidget struct to a new address
6. The old memory is returned to the allocator and reused (e.g. by
   WebKit for internal strings like "mergeDelete")
7. A WebKit callback fires, retrieves the now-stale pointer, and either:
   - Dereferences corrupted data (reading garbage fields), or
   - Passes the stale pointer to `store_xwidget_event_string`, which
     creates a Lisp event referencing corrupted memory
8. When `xwidget-event-handler` tries to format the event with `%S`,
   `print_object` follows the corrupted xwidget pseudo-vector and
   encounters an invalid type or pointer, calling `emacs_abort()`

The crash can occur on the very first page load, before any user
interaction, because WebKit fires multiple navigation callbacks
(`load-started`, `load-redirected`, `load-committed`, `load-finished`)
in sequence, and MPS can collect between any two of them.

### Why it does not affect the traditional GC

The traditional (non-IGC) Emacs GC is a non-moving mark-and-sweep
collector.  Objects remain at their allocated address for their entire
lifetime, so raw C pointers stored in ObjC/GObject memory remain valid
as long as the object is reachable from Lisp (which it is, via
`Vxwidget_list`).

## Fix

Allocate xwidgets and xwidget views as **immovable and pinned** in MPS,
the same treatment already applied to `PVEC_THREAD` and
`PVEC_MODULE_GLOBAL_REFERENCE`.

### Why both `alloc_immovable` and `pin` are needed

`alloc_immovable` allocates from a separate AMC pool
(`immovable_pool`), but both `dflt_pool` and `immovable_pool` use the
same `mps_class_amc()` pool class.  AMC is a moving collector --
objects are only pinned if an **ambiguous reference** exists.  Without
an explicit `pin()` call, MPS can still move objects whose only
references are exact (traced Lisp pointers).

The `pin()` function adds an ambiguous reference to the IGC pin
registry, which:
1. Prevents MPS from moving the object (ambiguous refs cannot be updated)
2. Prevents MPS from collecting the object (the pin acts as a root)

The `unpin()` call in `kill_xwidget` / `Fdelete_xwidget_view` removes
the pin after all toolkit resources (and their raw pointers) have been
destroyed, allowing MPS to collect the struct normally.

### Changes

**`src/xwidget.h`**: Add `pin_index` field (under `#ifdef HAVE_MPS`)
to both `struct xwidget` and `struct xwidget_view`.

**`src/igc.c`** (`igc_alloc_pseudovector`): Allocate from
`immovable_pool` and pin at creation:

```c
#ifdef HAVE_XWIDGETS
  else if (tag == PVEC_XWIDGET || tag == PVEC_XWIDGET_VIEW)
    {
      v = alloc_immovable (size, IGC_OBJ_VECTOR);
      if (tag == PVEC_XWIDGET)
        ((struct xwidget *) v)->pin_index = pin (global_igc, v);
      else
        ((struct xwidget_view *) v)->pin_index = pin (global_igc, v);
    }
#endif
```

**`src/igc.c`** / **`src/igc.h`**: Add `igc_unpin_xwidget` and
`igc_unpin_xwidget_view` functions.

**`src/xwidget.c`** (`kill_xwidget`): Call `igc_unpin_xwidget(xw)`
after all toolkit cleanup (GTK widget destruction / `nsxwidget_kill`),
so the raw pointers are gone before the pin is released.

**`src/xwidget.c`** (`Fdelete_xwidget_view`): Call
`igc_unpin_xwidget_view(xv)` after removing from the view list.

### Trade-offs

- **Memory fragmentation**: Pinned objects cannot be compacted,
  leaving holes in pool segments.  Negligible in practice since users
  create at most a handful of xwidgets.
- **Deferred collection**: A pinned xwidget cannot be collected even
  if unreachable from Lisp, until `kill_xwidget` unpins it.  This
  matches the existing lifecycle -- xwidgets hold OS-level resources
  (WebKit views) that require explicit teardown anyway.
- **No extra overhead**: `pin`/`unpin` are simple array index
  operations in the IGC pin registry.

## Alternative approaches considered

### 1. ID-based indirection (no pinning, no raw pointers)

Instead of storing a raw `struct xwidget *`, store the integer
`xwidget_id` and look up the xwidget via `xwidget_from_id()` at the
start of each callback.  Since `xwidget_id` is a plain integer, MPS
movement has no effect on it.  `xwidget_from_id` returns a fresh
pointer derived from a Lisp hash table reference that MPS keeps
up to date.

This is the **only approach that fully avoids pinning**.

**NS changes required** (`src/nsxwidget.m`):

- Change `@property struct xwidget *xw` to `@property uint32_t xwidget_id`
- Refactor 12 call sites that dereference `self.xw->...`:
  - Navigation callbacks (`didFinishNavigation:` etc.) -- straightforward,
    add `struct xwidget *xw = xwidget_from_id(self.xwidget_id)` at top
  - Mouse handlers (`mouseDown:`, `mouseUp:`) -- called on every click,
    adds a hash lookup per event
  - `keyDown:` -- has an **async completion block** (line 262) that
    captures `self` and dereferences `self.xw->xv->emacswindow` when
    the JS evaluation completes later.  The xwidget could be killed
    between dispatch and callback, requiring a liveness check
  - `userContentController:didReceiveScriptMessage:` -- same issue

**GTK changes required** (`src/xwidget.c`):

- Change `g_object_set_data(obj, XG_XWIDGET, xw)` to store the ID via
  `GINT_TO_POINTER(xw->xwidget_id)`
- Refactor 3 `g_object_get_data` call sites to do
  `xwidget_from_id(GPOINTER_TO_INT(...))`
- Several of these callbacks access xwidget fields deeply
  (`xw->script_callbacks`, `xw->widget_osr`, etc.)

**Problems**:

- `xwidget_from_id` currently calls `emacs_abort()` on lookup failure.
  It would need to return NULL gracefully for the case where the
  xwidget was killed between event dispatch and callback execution.
  Every call site would need a NULL check.
- `xwidget_from_id` calls `Fgethash`, which allocates Lisp objects.
  Allocations can trigger MPS collection.  This is safe on the main
  thread but adds GC pressure to hot paths (mouse/keyboard handlers).
- Total: ~16 call sites across 3 files need refactoring, plus error
  handling changes to `xwidget_from_id` itself.

**Verdict**: Correct and avoids pinning entirely.  However, it is a
significantly more invasive change, touches hot input-handling paths,
and requires careful auditing of the async ObjC completion blocks.
Better suited as a follow-up cleanup than an initial bug fix.

### 2. Register ObjC/GObject pointers as MPS roots

Register the external pointer locations as exact MPS roots so MPS can
update them when moving objects.  This would preserve the benefits of a
moving collector but adds significant complexity:
- ObjC: would require tracking the lifecycle of every `XwWebView` to
  add/remove roots, and getting the stable address of the ObjC ivar
- GTK: `g_object_set_data` stores into an opaque hash table whose
  slot addresses are not stable, making exact root registration
  impractical

**Verdict**: Not feasible for GTK.  Possible but fragile for NS.

### 3. Use Lisp_Object instead of raw pointers

Store a `Lisp_Object` (tagged pointer) in the external object and
register it as an ambiguous root.  Ambiguous references pin objects,
effectively making them immovable anyway, with more overhead than
explicit pinning.

**Verdict**: Strictly worse than pinning -- same immovability outcome
with more complexity.

### 4. Pin only on NS

The GTK backend has the same fundamental problem (raw pointers in
`g_object_set_data`), so a toolkit-specific fix would be incomplete.

## Scope

This fix applies to both `PVEC_XWIDGET` and `PVEC_XWIDGET_VIEW` since
xwidget views also store raw pointers in GObject user data
(`XG_XWIDGET_VIEW` key) and are accessed from GTK signal handlers.

## Related code

- `src/igc.c`: `igc_alloc_pseudovector` -- allocation and fix location
- `src/igc.c`: `fix_xwidget`, `fix_xwidget_view` -- MPS scan functions
- `src/xwidget.c`: `allocate_xwidget`, `store_xwidget_event_string`,
  `g_object_set_data` calls
- `src/nsxwidget.m`: `XwWebView` class, WKNavigationDelegate methods
- `lisp/xwidget.el`: `xwidget-event-handler`, `xwidget-log`
