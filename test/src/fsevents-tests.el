;;; fsevents-tests.el --- Tests for fsevents file notification backend  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for the FSEvents file notification backend (macOS).

;;; Code:

(require 'ert)
(require 'cl-lib)

(declare-function fsevents-add-watch "fsevents.m" (file flags callback))
(declare-function fsevents-rm-watch "fsevents.m" (watch-descriptor))
(declare-function fsevents-valid-p "fsevents.m" (watch-descriptor))
(declare-function fsevents--debug-stream-count "fsevents.m" ())
(declare-function fsevents--debug-enqueue-empty-batch "fsevents.m" (stream-id))
(declare-function fsevents--debug-inject-empty-batch-during-read "fsevents.m" (stream-id))
(declare-function fsevents--debug-watch-stream-id "fsevents.m" (watch-descriptor))
(declare-function fsevents--debug-enqueue-overflow-batch "fsevents.m" (stream-id path))
(declare-function fsevents--debug-enqueue-overflow-write-batch "fsevents.m" (stream-id overflow-path file-path))
(declare-function fsevents--debug-enqueue-delete-batch "fsevents.m" (stream-id path))
(declare-function fsevents--debug-enqueue-root-changed-batch "fsevents.m" (stream-id path))
(declare-function fsevents--debug-write-wake-bytes "fsevents.m" (count))
(declare-function fsevents--debug-drain-wake-bytes "fsevents.m" ())
(declare-function fsevents--debug-handle-pipe-ready "fsevents.m" ())

(defconst fsevents-tests--available (featurep 'fsevents)
  "Non-nil if the fsevents backend is available.
FSEvents uses a GCD dispatch queue, so it works in all Emacs
configurations: GUI, daemon, terminal, and batch mode.")

(defun fsevents-tests--spin-for (seconds)
  "Busy-wait for SECONDS without entering the Emacs event loop."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline))))

(ert-deftest fsevents-test-add-watch ()
  "Test that `fsevents-add-watch' returns an integer descriptor."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (desc (fsevents-add-watch tmpdir '(create delete write)
                                   #'ignore)))
    (unwind-protect
        (progn
          (should (integerp desc))
          (should (eq t (fsevents-valid-p desc))))
      (fsevents-rm-watch desc)
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-rm-watch ()
  "Test that `fsevents-rm-watch' invalidates the descriptor."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (desc (fsevents-add-watch tmpdir '(create delete write)
                                   #'ignore)))
    (unwind-protect
        (progn
          (should (eq t (fsevents-valid-p desc)))
          (fsevents-rm-watch desc)
          (should (eq nil (fsevents-valid-p desc))))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-add-watch-missing-file ()
  "Test that missing leaf files can still be watched."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (missing (expand-file-name "missing.txt" tmpdir))
         (desc (fsevents-add-watch missing '(create delete write)
                                   #'ignore)))
    (unwind-protect
        (progn
          (should (integerp desc))
          (should (eq t (fsevents-valid-p desc))))
      (fsevents-rm-watch desc)
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-share-ancestor-stream ()
  "Nested watches under the same root should share one native stream."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         root-desc sub-desc)
    (make-directory subdir)
    (unwind-protect
        (progn
          (setq root-desc (fsevents-add-watch tmpdir '(create) #'ignore))
          (should (= 1 (fsevents--debug-stream-count)))
          (setq sub-desc (fsevents-add-watch subdir '(create) #'ignore))
          (should (= 1 (fsevents--debug-stream-count)))
          (fsevents-rm-watch root-desc)
          (setq root-desc nil)
          (should (= 1 (fsevents--debug-stream-count)))
          (fsevents-rm-watch sub-desc)
          (setq sub-desc nil)
          (should (= 0 (fsevents--debug-stream-count))))
      (when sub-desc
        (fsevents-rm-watch sub-desc))
      (when root-desc
        (fsevents-rm-watch root-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-collapse-descendant-streams ()
  "Adding an ancestor watch should collapse descendant native streams."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         root-desc sub-desc)
    (make-directory subdir)
    (unwind-protect
        (progn
          (setq sub-desc (fsevents-add-watch subdir '(create) #'ignore))
          (should (= 1 (fsevents--debug-stream-count)))
          (setq root-desc (fsevents-add-watch tmpdir '(create) #'ignore))
          (should (= 1 (fsevents--debug-stream-count)))
          (fsevents-rm-watch sub-desc)
          (setq sub-desc nil)
          (should (= 1 (fsevents--debug-stream-count)))
          (fsevents-rm-watch root-desc)
          (setq root-desc nil)
          (should (= 0 (fsevents--debug-stream-count))))
      (when sub-desc
        (fsevents-rm-watch sub-desc))
      (when root-desc
        (fsevents-rm-watch root-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-collapse-keeps-queued-batches-alive ()
  "Queued batches from a retired stream should still reach moved watches."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         (testfile (expand-file-name "queued.txt" subdir))
         (events nil)
         (root-events nil)
         root-desc sub-desc)
    (make-directory subdir)
    (unwind-protect
        (progn
          (setq sub-desc
                (fsevents-add-watch
                 subdir '(create)
                 (lambda (ev) (push ev events))))
          (write-region "queued" nil testfile)
          ;; Let the FSEvents dispatch queue enqueue the raw batch,
          ;; but do not enter the main-thread event loop yet.
          (fsevents-tests--spin-for 0.3)
          (setq root-desc (fsevents-add-watch
                           tmpdir '(create)
                           (lambda (ev) (push ev root-events))))
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (and (memq 'create (nth 1 ev))
                                  (equal testfile (nth 2 ev))))
                           events))
          (should-not root-events)
          (should (= 1 (fsevents--debug-stream-count))))
      (when root-desc
        (fsevents-rm-watch root-desc))
      (when sub-desc
        (fsevents-rm-watch sub-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-promote-sibling-streams ()
  "Many sibling watches should be promoted to one parent native stream."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdirs (mapcar (lambda (n)
                            (expand-file-name (format "d%d" n) tmpdir))
                          (number-sequence 1 8)))
         (descs nil))
    (dolist (dir subdirs)
      (make-directory dir))
    (unwind-protect
        (progn
          (dolist (dir subdirs)
            (push (fsevents-add-watch dir '(create) #'ignore) descs))
          (should (= 1 (fsevents--debug-stream-count))))
      (dolist (desc descs)
        (when (fsevents-valid-p desc)
          (fsevents-rm-watch desc)))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-file-create-event ()
  "Test that creating a file generates a `create' event."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (events nil)
         (desc (fsevents-add-watch
                tmpdir '(create delete write attrib rename)
                (lambda (ev) (push ev events)))))
    (unwind-protect
        (progn
          (write-region "hello" nil (expand-file-name "newfile.txt" tmpdir))
          ;; Wait for FSEvents to deliver the event.
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (memq 'create (nth 1 ev)))
                           events)))
      (fsevents-rm-watch desc)
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-read-callback-leaves-surplus-wake-bytes ()
  "The read callback should handle queued batches before draining the pipe."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (desc (fsevents-add-watch tmpdir '(create) #'ignore)))
    (unwind-protect
        (progn
          (fsevents--debug-enqueue-empty-batch -1)
          (should (= 256 (fsevents--debug-write-wake-bytes 256)))
          (fsevents--debug-handle-pipe-ready)
          (should (> (fsevents--debug-drain-wake-bytes) 0)))
      (ignore-errors (fsevents--debug-drain-wake-bytes))
      (when (fsevents-valid-p desc)
        (fsevents-rm-watch desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-read-callback-rearms-no-wake-tail ()
  "Batches appended during a read callback should be re-armed."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (desc (fsevents-add-watch tmpdir '(create) #'ignore)))
    (unwind-protect
        (progn
          (fsevents--debug-enqueue-empty-batch -1)
          (fsevents--debug-inject-empty-batch-during-read -1)
          (fsevents--debug-handle-pipe-ready)
          (should (> (fsevents--debug-drain-wake-bytes) 0)))
      (ignore-errors (fsevents--debug-drain-wake-bytes))
      (when (fsevents-valid-p desc)
        (fsevents-rm-watch desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-overflow-on-file-watch-stays-silent ()
  "File watches should not fabricate writes on shared-stream overflow."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         (testfile (expand-file-name "target.txt" tmpdir))
         (events nil)
         (root-events nil)
         file-desc root-desc)
    (make-directory subdir)
    (write-region "content" nil testfile)
    (unwind-protect
        (progn
          (setq file-desc
                (fsevents-add-watch
                 testfile '(create delete write attrib rename)
                 (lambda (ev) (push ev events))))
          (setq root-desc
                (fsevents-add-watch
                 tmpdir '(create)
                 (lambda (ev) (push ev root-events))))
          (should (= (fsevents--debug-watch-stream-id file-desc)
                     (fsevents--debug-watch-stream-id root-desc)))
          (fsevents--debug-enqueue-overflow-batch
           (fsevents--debug-watch-stream-id root-desc)
           subdir)
          (sit-for 1)
          (should-not events)
          (should (cl-some (lambda (ev)
                             (and (memq 'create (nth 1 ev))
                                  (equal tmpdir (nth 2 ev))))
                           root-events)))
      (when (and root-desc (fsevents-valid-p root-desc))
        (fsevents-rm-watch root-desc))
      (when (and file-desc (fsevents-valid-p file-desc))
        (fsevents-rm-watch file-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-overflow-only-rescans-covered-sibling ()
  "Overflow on one promoted sibling should not rescan another."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdirs (mapcar (lambda (n)
                            (expand-file-name (format "d%d" n) tmpdir))
                          (number-sequence 1 8)))
         (busy-dir (car subdirs))
         (quiet-dir (cadr subdirs))
         (busy-deep (expand-file-name "nested/child" busy-dir))
         (busy-events nil)
         (quiet-events nil)
         (descs nil)
         busy-desc quiet-desc)
    (dolist (dir subdirs)
      (make-directory dir))
    (make-directory (file-name-directory busy-deep) t)
    (unwind-protect
        (progn
          (dolist (dir subdirs)
            (let ((callback #'ignore))
              (cond
               ((equal dir busy-dir)
                (setq busy-desc
                      (fsevents-add-watch
                       dir '(create)
                       (lambda (ev) (push ev busy-events))))
                (push busy-desc descs))
               ((equal dir quiet-dir)
                (setq quiet-desc
                      (fsevents-add-watch
                       dir '(create)
                       (lambda (ev) (push ev quiet-events))))
                (push quiet-desc descs))
               (t
                (push (fsevents-add-watch dir '(create) callback) descs)))))
          (should (= 1 (fsevents--debug-stream-count)))
          (should (= (fsevents--debug-watch-stream-id busy-desc)
                     (fsevents--debug-watch-stream-id quiet-desc)))
          (fsevents--debug-enqueue-overflow-batch
           (fsevents--debug-watch-stream-id busy-desc)
           busy-deep)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (and (memq 'create (nth 1 ev))
                                  (equal busy-dir (nth 2 ev))))
                           busy-events))
          (should-not quiet-events))
      (dolist (desc descs)
        (when (fsevents-valid-p desc)
          (fsevents-rm-watch desc)))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-overflow-batch-keeps-later-file-event ()
  "A MustScanSubDirs entry must not discard later concrete events."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         (testfile (expand-file-name "target.txt" tmpdir))
         (file-events nil)
         (root-events nil)
         file-desc root-desc)
    (make-directory subdir)
    (write-region "content" nil testfile)
    (unwind-protect
        (progn
          (setq file-desc
                (fsevents-add-watch
                 testfile '(write)
                 (lambda (ev) (push ev file-events))))
          (setq root-desc
                (fsevents-add-watch
                 tmpdir '(create)
                 (lambda (ev) (push ev root-events))))
          (should (= (fsevents--debug-watch-stream-id file-desc)
                     (fsevents--debug-watch-stream-id root-desc)))
          (fsevents--debug-enqueue-overflow-write-batch
           (fsevents--debug-watch-stream-id root-desc)
           subdir testfile)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (and (memq 'write (nth 1 ev))
                                  (equal testfile (nth 2 ev))))
                           file-events))
          (should (cl-some (lambda (ev)
                             (and (memq 'create (nth 1 ev))
                                  (equal tmpdir (nth 2 ev))))
                           root-events)))
      (when (and root-desc (fsevents-valid-p root-desc))
        (fsevents-rm-watch root-desc))
      (when (and file-desc (fsevents-valid-p file-desc))
        (fsevents-rm-watch file-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-shared-directory-root-delete-stops-watch ()
  "A shared directory watch should stop when its own root is removed."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         (events nil)
         sub-desc root-desc)
    (make-directory subdir)
    (unwind-protect
        (progn
          (setq sub-desc
                (fsevents-add-watch
                 subdir '(attrib)
                 (lambda (ev) (push ev events))))
          (setq root-desc (fsevents-add-watch tmpdir '(create) #'ignore))
          (should (= (fsevents--debug-watch-stream-id sub-desc)
                     (fsevents--debug-watch-stream-id root-desc)))
          (fsevents--debug-enqueue-delete-batch
           (fsevents--debug-watch-stream-id root-desc)
           subdir)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (memq 'stopped (nth 1 ev)))
                           events))
          (should-not (fsevents-valid-p sub-desc)))
      (when (and root-desc (fsevents-valid-p root-desc))
        (fsevents-rm-watch root-desc))
      (when (and sub-desc (fsevents-valid-p sub-desc))
        (fsevents-rm-watch sub-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-shared-directory-root-delete-invalidates-direct-watch ()
  "A shared directory root delete should invalidate direct clients too."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         (events nil)
         sub-desc root-desc)
    (make-directory subdir)
    (unwind-protect
        (progn
          (setq sub-desc
                (fsevents-add-watch
                 subdir '(delete)
                 (lambda (ev) (push ev events))))
          (setq root-desc (fsevents-add-watch tmpdir '(create) #'ignore))
          (should (= (fsevents--debug-watch-stream-id sub-desc)
                     (fsevents--debug-watch-stream-id root-desc)))
          (fsevents--debug-enqueue-delete-batch
           (fsevents--debug-watch-stream-id root-desc)
           subdir)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (memq 'delete (nth 1 ev)))
                           events))
          (should-not (fsevents-valid-p sub-desc)))
      (when (and root-desc (fsevents-valid-p root-desc))
        (fsevents-rm-watch root-desc))
      (when (and sub-desc (fsevents-valid-p sub-desc))
        (fsevents-rm-watch sub-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-shared-root-changed-stops-descendant-plainly ()
  "Shared RootChanged should not forward the ancestor path to descendants."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         (events nil)
         sub-desc root-desc)
    (make-directory subdir)
    (unwind-protect
        (progn
          (setq sub-desc
                (fsevents-add-watch
                 subdir '(create delete write attrib rename)
                 (lambda (ev) (push ev events))))
          (setq root-desc
                (fsevents-add-watch
                 tmpdir '(create delete write attrib rename)
                 #'ignore))
          (should (= (fsevents--debug-watch-stream-id sub-desc)
                     (fsevents--debug-watch-stream-id root-desc)))
          (fsevents--debug-enqueue-root-changed-batch
           (fsevents--debug-watch-stream-id root-desc)
           tmpdir)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (and (equal subdir (nth 2 ev))
                                  (equal '(stopped) (nth 1 ev))))
                           events))
          (should-not (cl-some (lambda (ev)
                                 (and (equal tmpdir (nth 2 ev))
                                      (or (memq 'delete (nth 1 ev))
                                          (memq 'rename (nth 1 ev)))))
                               events))
          (should-not (fsevents-valid-p sub-desc)))
      (when (and root-desc (fsevents-valid-p root-desc))
        (fsevents-rm-watch root-desc))
      (when (and sub-desc (fsevents-valid-p sub-desc))
        (fsevents-rm-watch sub-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-trailing-slash-directory-root-delete ()
  "Directory watches should treat trailing-slash roots identically."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdir (expand-file-name "sub" tmpdir))
         (events nil)
         desc)
    (make-directory subdir)
    (unwind-protect
        (progn
          (setq desc
                (fsevents-add-watch
                 (file-name-as-directory subdir) '(delete)
                 (lambda (ev) (push ev events))))
          (fsevents--debug-enqueue-delete-batch
           (fsevents--debug-watch-stream-id desc)
           subdir)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (and (equal subdir (nth 2 ev))
                                  (memq 'delete (nth 1 ev))))
                           events))
          (should-not (fsevents-valid-p desc)))
      (when (and desc (fsevents-valid-p desc))
        (fsevents-rm-watch desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-file-modify-event ()
  "Test that modifying a file generates a `write' event."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (testfile (expand-file-name "existing.txt" tmpdir))
         (events nil)
         desc)
    (write-region "initial" nil testfile)
    (sit-for 0.5) ;; Let the file settle before watching.
    (setq desc (fsevents-add-watch
                tmpdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (write-region "modified" nil testfile)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (memq 'write (nth 1 ev)))
                           events)))
      (fsevents-rm-watch desc)
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-file-delete-event ()
  "Test that deleting a file generates a `delete' event."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (testfile (expand-file-name "todelete.txt" tmpdir))
         (events nil)
         desc)
    (write-region "content" nil testfile)
    (sit-for 0.5)
    (setq desc (fsevents-add-watch
                tmpdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (delete-file testfile)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (memq 'delete (nth 1 ev)))
                           events)))
      (fsevents-rm-watch desc)
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-symlink-no-events ()
  "Test that watching a symlink suppresses non-terminal non-attribute events.
Matches inotify IN_DONT_FOLLOW: writes to the target, child creation
inside a symlinked directory produce no events; deleting the symlink
stops the direct watch."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (target-file (expand-file-name "target.txt" tmpdir))
         (link-file (concat tmpdir "-link"))
         (events nil)
         desc)
    ;; Symlink to a regular file.
    (write-region "initial" nil target-file)
    (make-symbolic-link target-file link-file)
    (setq desc (fsevents-add-watch
                link-file '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (should (integerp desc))
          (should (eq t (fsevents-valid-p desc)))
          ;; Writing to the target through the symlink: no events.
          (write-region "modified" nil link-file)
          (sit-for 1)
          (should-not events)
          ;; Deleting the symlink should preserve the terminal marker
          ;; for direct callers and invalidate the watch.
          (delete-file link-file)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (and (equal link-file (nth 2 ev))
                                  (equal '(delete stopped) (nth 1 ev))))
                           events))
          (should (eq nil (fsevents-valid-p desc))))
      (when (fsevents-valid-p desc)
        (fsevents-rm-watch desc))
      (ignore-errors (delete-file link-file))
      (delete-directory tmpdir t)))

  ;; Symlink to a directory: child events suppressed.
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (linkdir (concat tmpdir "-link"))
         (events nil)
         desc)
    (make-symbolic-link tmpdir linkdir)
    (setq desc (fsevents-add-watch
                linkdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (should (integerp desc))
          (write-region "hello" nil (expand-file-name "child.txt" tmpdir))
          (sit-for 1)
          (should-not events))
      (when (fsevents-valid-p desc)
        (fsevents-rm-watch desc))
      (ignore-errors (delete-file linkdir))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-symlink-dir-trailing-slash-behaves-like-leaf ()
  "Slash-suffixed symlink directories should stay on symlink semantics."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (linkdir (concat tmpdir "-link"))
         (events nil)
         desc)
    (make-symbolic-link tmpdir linkdir)
    (setq desc (fsevents-add-watch
                (file-name-as-directory linkdir)
                '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (write-region "hello" nil (expand-file-name "child.txt" tmpdir))
          (sit-for 1)
          (should-not events)
          (delete-file linkdir)
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (and (equal linkdir (nth 2 ev))
                                  (equal '(delete stopped) (nth 1 ev))))
                           events))
          (should-not (fsevents-valid-p desc)))
      (when (and desc (fsevents-valid-p desc))
        (fsevents-rm-watch desc))
      (ignore-errors (delete-file linkdir))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-symlink-mid-path ()
  "Test that a symlink in a middle path component is resolved.
E.g. /tmp/real/sub where /tmp/link -> /tmp/real, watching /tmp/link/sub."
  (skip-unless fsevents-tests--available)
  (let* ((realdir (make-temp-file "fsevents-real" t))
         (subdir (expand-file-name "sub" realdir))
         (linkdir (concat realdir "-link"))
         (link-subdir (expand-file-name "sub" linkdir))
         (events nil)
         desc)
    (make-directory subdir)
    (make-symbolic-link realdir linkdir)
    (setq desc (fsevents-add-watch
                link-subdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (should (integerp desc))
          (write-region "data" nil
                        (expand-file-name "mid-link.txt" link-subdir))
          (sit-for 1)
          (should (cl-some (lambda (ev)
                             (memq 'create (nth 1 ev)))
                           events)))
      (fsevents-rm-watch desc)
      (delete-file linkdir)
      (delete-directory realdir t))))

(ert-deftest fsevents-test-symlink-mid-path-preserves-namespace ()
  "Test that events through a mid-path symlink use the caller's path.
When watching /tmp/link/sub (where link is a symlink to /tmp/real),
events should report paths under /tmp/link/sub, not /tmp/real/sub."
  (skip-unless fsevents-tests--available)
  (let* ((realdir (make-temp-file "fsevents-real" t))
         (subdir (expand-file-name "sub" realdir))
         (linkdir (concat realdir "-link"))
         (link-subdir (expand-file-name "sub" linkdir))
         (events nil)
         desc)
    (make-directory subdir)
    (make-symbolic-link realdir linkdir)
    (setq desc (fsevents-add-watch
                link-subdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (should (integerp desc))
          (write-region "data" nil
                        (expand-file-name "ns-test.txt" link-subdir))
          (sit-for 1)
          ;; Event path should use the caller's link-subdir prefix,
          ;; not the resolved realdir prefix.
          (let ((create-ev (cl-find-if (lambda (ev)
                                         (memq 'create (nth 1 ev)))
                                       events)))
            (should create-ev)
            (let ((event-path (nth 2 create-ev)))
              (should (string-prefix-p
                       (file-name-as-directory link-subdir)
                       event-path))
              (should-not (string-prefix-p
                           (file-name-as-directory subdir)
                           event-path)))))
      (fsevents-rm-watch desc)
      (delete-file linkdir)
      (delete-directory realdir t))))

(ert-deftest fsevents-test-invalid-args ()
  "Test that invalid arguments signal errors."
  (skip-unless fsevents-tests--available)
  ;; Nonexistent directory should signal an error.
  (should-error (fsevents-add-watch "/nonexistent/path/fsevents-test"
                                    '(create) #'ignore)
                :type 'file-error)
  ;; Invalid descriptor should signal an error.
  (should-error (fsevents-rm-watch 99999)
                :type 'file-notify-error))

;;; fsevents-tests.el ends here
