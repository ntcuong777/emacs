/* syspoll.h - System-dependent definitions for the poll function.
   Copyright (C) 2022 Free Software Foundation, Inc.

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

#ifndef SYSPOLL_H
#define SYSPOLL_H 1

#if !defined (DOS_NT) && !defined (WINDOWSNT)
#include <poll.h>

/* The conversion helpers (fd_sets_to_pollfds, pollfds_to_fd_sets) are
   static in process.c.  Only the public entry points are declared here.  */
extern int timespec_to_timeout (const struct timespec *);
extern int emacs_pselect (int, emacs_fd_set *, emacs_fd_set *,
			  emacs_fd_set *, const struct timespec *,
			  const sigset_t *);
#endif
#endif
