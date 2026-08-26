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
(require 'filenotify)

(declare-function fsevents-add-watch "fsevents.m" (file flags callback))
(declare-function fsevents-rm-watch "fsevents.m" (watch-descriptor))
(declare-function fsevents-valid-p "fsevents.m" (watch-descriptor))
(declare-function fsevents--debug-stream-count "fsevents.m" ())
(declare-function fsevents--debug-queue-counts "fsevents.m" ())
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
(declare-function fsevents--debug-reset-performance-counters "fsevents.m" ())
(declare-function fsevents--debug-performance-counters "fsevents.m" ())
(declare-function fsevents--debug-enqueue-rename-batch "fsevents.m" (stream-id events))

(defconst fsevents-tests--available (featurep 'fsevents)
  "Non-nil if the fsevents backend is available.
FSEvents uses a GCD dispatch queue, so it works in all Emacs
configurations: GUI, daemon, terminal, and batch mode.")

(defun fsevents-tests--spin-for (seconds)
  "Busy-wait for SECONDS without entering the Emacs event loop."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline))))

(defun fsevents-tests--pump-events (seconds)
  "Dispatch queued special events (e.g. `file-notify') for SECONDS.

In `--batch' mode, `sit-for' does not run the command loop far enough
to dispatch `special-event-map' bindings for already-queued
`file-notify' events; `read-event' does.  Tests that wait for a
callback to fire (whether from a real FSEvents callback or from a
synthetic batch injected via the debug helpers) must pump with this
function instead of `sit-for'."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (read-event nil nil 0.05))))

(ert-deftest fsevents-test-event-limit-overflow-rescans-watches ()
  "A finite event limit emits one rescan per affected logical watch."
  (skip-unless fsevents-tests--available)
  (let* ((original file-notify-fsevents-event-limit)
         (tmpdir (make-temp-file "fsevents-limit" t))
         (testfile (expand-file-name "target.txt" tmpdir))
         (dir-events nil)
         (file-events nil)
         dir-desc file-desc
         (entries (mapcar (lambda (n)
                            (list (expand-file-name
                                   (format "storm-%d" n) tmpdir)
                                  nil))
                          (number-sequence 0 4))))
    (write-region "content" nil testfile)
    (unwind-protect
        (progn
          (customize-set-variable 'file-notify-fsevents-event-limit 4)
          (setq dir-desc
                (fsevents-add-watch
                 tmpdir '(create)
                 (lambda (ev) (push ev dir-events))))
          (setq file-desc
                (fsevents-add-watch
                 testfile '(write)
                 (lambda (ev) (push ev file-events))))
          (should (= (fsevents--debug-watch-stream-id dir-desc)
                     (fsevents--debug-watch-stream-id file-desc)))
          (fsevents-tests--pump-events 0.2)
          (setq dir-events nil file-events nil)
          (fsevents--debug-enqueue-rename-batch
           (fsevents--debug-watch-stream-id dir-desc) entries)
          (should (equal '(1 0 1) (fsevents--debug-queue-counts)))
          (fsevents--debug-handle-pipe-ready)
          (fsevents-tests--pump-events 0.5)
          (let ((dir-summaries
                 (cl-remove-if-not
                  (lambda (ev)
                    (and (equal '(create) (nth 1 ev))
                         (equal tmpdir (nth 2 ev))))
                  dir-events))
                (file-summaries
                 (cl-remove-if-not
                  (lambda (ev)
                    (and (equal '(write) (nth 1 ev))
                         (equal testfile (nth 2 ev))))
                  file-events)))
            (should (= 1 (length dir-summaries)))
            (should (= 1 (length file-summaries))))
          (should (fsevents-valid-p dir-desc))
          (should (fsevents-valid-p file-desc))
          (should (equal '(0 0 0) (fsevents--debug-queue-counts))))
      (when (and file-desc (fsevents-valid-p file-desc))
        (fsevents-rm-watch file-desc))
      (when (and dir-desc (fsevents-valid-p dir-desc))
        (fsevents-rm-watch dir-desc))
      (delete-directory tmpdir t)
      (customize-set-variable 'file-notify-fsevents-event-limit original))))

(ert-deftest fsevents-test-event-limit-deduplicates-markers ()
  "Additional detail on an overloaded stream does not duplicate its marker."
  (skip-unless fsevents-tests--available)
  (let* ((original file-notify-fsevents-event-limit)
         (tmpdir (make-temp-file "fsevents-limit" t))
         (testfile (expand-file-name "target.txt" tmpdir))
         (dir-events nil)
         (file-events nil)
         dir-desc file-desc
         (entries (mapcar (lambda (n)
                            (list (expand-file-name
                                   (format "storm-%d" n) tmpdir)
                                  nil))
                          (number-sequence 0 4))))
    (write-region "content" nil testfile)
    (unwind-protect
        (progn
          (customize-set-variable 'file-notify-fsevents-event-limit 4)
          (setq dir-desc
                (fsevents-add-watch
                 tmpdir '(create)
                 (lambda (ev) (push ev dir-events))))
          (setq file-desc
                (fsevents-add-watch
                 testfile '(write)
                 (lambda (ev) (push ev file-events))))
          (fsevents-tests--pump-events 0.2)
          (setq dir-events nil file-events nil)
          (setq entries
                (mapcar (lambda (entry) (list (car entry) nil)) entries))
          (let ((stream-id (fsevents--debug-watch-stream-id dir-desc)))
            (fsevents--debug-enqueue-rename-batch stream-id entries)
            (should (equal '(1 0 1) (fsevents--debug-queue-counts)))
            (fsevents--debug-enqueue-rename-batch
             stream-id (list (list (expand-file-name "later" tmpdir) nil)))
            (should (equal '(1 0 1) (fsevents--debug-queue-counts))))
          (fsevents--debug-handle-pipe-ready)
          (fsevents-tests--pump-events 0.5)
          (should (= 1 (length
                        (cl-remove-if-not
                         (lambda (ev)
                           (and (equal '(create) (nth 1 ev))
                                (equal tmpdir (nth 2 ev))))
                         dir-events))))
          (should (= 1 (length
                        (cl-remove-if-not
                         (lambda (ev)
                           (and (equal '(write) (nth 1 ev))
                                (equal testfile (nth 2 ev))))
                         file-events))))
          (should (equal '(0 0 0) (fsevents--debug-queue-counts))))
      (when (and file-desc (fsevents-valid-p file-desc))
        (fsevents-rm-watch file-desc))
      (when (and dir-desc (fsevents-valid-p dir-desc))
        (fsevents-rm-watch dir-desc))
      (delete-directory tmpdir t)
      (customize-set-variable 'file-notify-fsevents-event-limit original))))

(ert-deftest fsevents-test-event-limit-isolates-streams ()
  "Queue overflow on one native stream preserves another stream's detail."
  (skip-unless fsevents-tests--available)
  (let* ((original file-notify-fsevents-event-limit)
         (busy-root (make-temp-file "fsevents-busy" t))
         (quiet-root (make-temp-file "fsevents-quiet" t))
         (busy-file (expand-file-name "target.txt" busy-root))
         (quiet-file (expand-file-name "target.txt" quiet-root))
         (busy-dir-events nil)
         (busy-file-events nil)
         (quiet-events nil)
         busy-dir-desc busy-file-desc quiet-desc
         (entries (mapcar (lambda (n)
                            (list (expand-file-name
                                   (format "storm-%d" n) busy-root)
                                  nil))
                          (number-sequence 0 4))))
    (write-region "busy" nil busy-file)
    (write-region "quiet" nil quiet-file)
    (unwind-protect
        (progn
          (customize-set-variable 'file-notify-fsevents-event-limit 4)
          (setq busy-dir-desc
                (fsevents-add-watch
                 busy-root '(create)
                 (lambda (ev) (push ev busy-dir-events))))
          (setq busy-file-desc
                (fsevents-add-watch
                 busy-file '(write)
                 (lambda (ev) (push ev busy-file-events))))
          (setq quiet-desc
                (fsevents-add-watch
                 quiet-root '(delete)
                 (lambda (ev) (push ev quiet-events))))
          (let ((busy-stream (fsevents--debug-watch-stream-id busy-dir-desc))
                (quiet-stream (fsevents--debug-watch-stream-id quiet-desc)))
            (should-not (= busy-stream quiet-stream))
            (fsevents-tests--pump-events 0.2)
            (setq busy-dir-events nil busy-file-events nil quiet-events nil)
            (fsevents--debug-enqueue-rename-batch busy-stream entries)
            (fsevents--debug-enqueue-delete-batch quiet-stream quiet-file)
            (should (equal '(2 1 1) (fsevents--debug-queue-counts))))
          (fsevents--debug-handle-pipe-ready)
          (fsevents-tests--pump-events 0.5)
          (should (= 1 (length
                        (cl-remove-if-not
                         (lambda (ev)
                           (and (equal '(create) (nth 1 ev))
                                (equal busy-root (nth 2 ev))))
                         busy-dir-events))))
          (should (= 1 (length
                        (cl-remove-if-not
                         (lambda (ev)
                           (and (equal '(write) (nth 1 ev))
                                (equal busy-file (nth 2 ev))))
                         busy-file-events))))
          (should (= 1 (length
                        (cl-remove-if-not
                         (lambda (ev)
                           (and (equal '(delete) (nth 1 ev))
                                (equal quiet-file (nth 2 ev))))
                         quiet-events))))
          (should-not (cl-some (lambda (ev) (equal '(create) (nth 1 ev)))
                               quiet-events))
          (should (fsevents-valid-p busy-dir-desc))
          (should (fsevents-valid-p busy-file-desc))
          (should (fsevents-valid-p quiet-desc))
          (should (equal '(0 0 0) (fsevents--debug-queue-counts))))
      (when (and quiet-desc (fsevents-valid-p quiet-desc))
        (fsevents-rm-watch quiet-desc))
      (when (and busy-file-desc (fsevents-valid-p busy-file-desc))
        (fsevents-rm-watch busy-file-desc))
      (when (and busy-dir-desc (fsevents-valid-p busy-dir-desc))
        (fsevents-rm-watch busy-dir-desc))
      (delete-directory busy-root t)
      (delete-directory quiet-root t)
      (customize-set-variable 'file-notify-fsevents-event-limit original))))

(ert-deftest fsevents-test-event-limit-nil-is-lossless ()
  "Nil preserves detailed batches while a finite limit collapses them."
  (skip-unless fsevents-tests--available)
  (let* ((original file-notify-fsevents-event-limit)
         (tmpdir (make-temp-file "fsevents-limit" t))
         (events nil)
         desc
         (entries (mapcar (lambda (n)
                            (list (expand-file-name
                                   (format "storm-%d" n) tmpdir)
                                  nil))
                          (number-sequence 0 4))))
    (unwind-protect
        (progn
          (setq desc
                (fsevents-add-watch
                 tmpdir '(create delete)
                 (lambda (ev) (push ev events))))
          (fsevents-tests--pump-events 0.2)
          (customize-set-variable 'file-notify-fsevents-event-limit nil)
          (fsevents--debug-enqueue-rename-batch
           (fsevents--debug-watch-stream-id desc) entries)
          (should (equal '(1 5 0) (fsevents--debug-queue-counts)))
          (fsevents--debug-handle-pipe-ready)
          (fsevents-tests--pump-events 0.5)
          (should (equal '(0 0 0) (fsevents--debug-queue-counts)))
          (setq events nil)
          (should-error
           (customize-set-variable 'file-notify-fsevents-event-limit 0))
          (should-error
           (customize-set-variable 'file-notify-fsevents-event-limit -1))
          (customize-set-variable 'file-notify-fsevents-event-limit 4)
          (fsevents--debug-enqueue-rename-batch
           (fsevents--debug-watch-stream-id desc) entries)
          (should (equal '(1 0 1) (fsevents--debug-queue-counts)))
          (fsevents--debug-handle-pipe-ready)
          (fsevents-tests--pump-events 0.5)
          (should (= 1 (length
                        (cl-remove-if-not
                         (lambda (ev)
                           (and (equal '(create) (nth 1 ev))
                                (equal tmpdir (nth 2 ev))))
                         events))))
          (should (equal '(0 0 0) (fsevents--debug-queue-counts))))
      (when (and desc (fsevents-valid-p desc))
        (fsevents-rm-watch desc))
      (delete-directory tmpdir t)
      (customize-set-variable 'file-notify-fsevents-event-limit original))))

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
          (fsevents-tests--pump-events 1)
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

(ert-deftest fsevents-test-recursive-directory-relevance ()
  "Recursive directory watches receive descendant events, unlike normal ones."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (nested (expand-file-name "nested" tmpdir))
         (deep-file (expand-file-name "deep.txt" nested))
         (recursive-events nil)
         (normal-events nil)
         recursive-desc normal-desc)
    (make-directory nested)
    (unwind-protect
        (progn
          (setq recursive-desc
                (fsevents-add-watch
                 tmpdir '(create recursive)
                 (lambda (ev) (push ev recursive-events))))
          (setq normal-desc
                (fsevents-add-watch
                 tmpdir '(create)
                 (lambda (ev) (push ev normal-events))))
          (fsevents--debug-enqueue-rename-batch
           (fsevents--debug-watch-stream-id recursive-desc)
           (list (list deep-file t)))
          (fsevents--debug-handle-pipe-ready)
          (fsevents-tests--pump-events 0.5)
          (should (cl-some (lambda (ev)
                            (and (equal deep-file (nth 2 ev))
                                 (memq 'create (nth 1 ev))))
                          recursive-events))
          (should-not (cl-some (lambda (ev) (equal deep-file (nth 2 ev)))
                                normal-events))
          (should-not (cl-some (lambda (ev) (memq 'recursive (nth 1 ev)))
                                recursive-events)))
      (when (and normal-desc (fsevents-valid-p normal-desc))
        (fsevents-rm-watch normal-desc))
      (when (and recursive-desc (fsevents-valid-p recursive-desc))
        (fsevents-rm-watch recursive-desc))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-recursive-file-watch-rejected ()
  "Recursive watches are rejected for files and symlinks."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (file (expand-file-name "file.txt" tmpdir))
         (link (expand-file-name "link.txt" tmpdir)))
    (write-region "content" nil file)
    (make-symbolic-link file link)
    (unwind-protect
        (progn
          (should-error (fsevents-add-watch file '(create recursive) #'ignore)
                        :type 'file-notify-error)
          (should-error (fsevents-add-watch link '(create recursive) #'ignore)
                        :type 'file-notify-error))
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
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
          (setq events nil root-events nil)

          (fsevents--debug-enqueue-overflow-batch
           (fsevents--debug-watch-stream-id root-desc)
           subdir)
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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
    (fsevents-tests--pump-events 0.5) ;; Let the file settle before watching.
    (setq desc (fsevents-add-watch
                tmpdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (write-region "modified" nil testfile)
          (fsevents-tests--pump-events 1)
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
    (fsevents-tests--pump-events 0.5)
    (setq desc (fsevents-add-watch
                tmpdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
    (unwind-protect
        (progn
          (delete-file testfile)
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
          (setq events nil)
          ;; Writing to the target through the symlink: no events.
          (write-region "modified" nil link-file)
          (fsevents-tests--pump-events 1)
          (should-not events)
          ;; Deleting the symlink should preserve the terminal marker
          ;; for direct callers and invalidate the watch.
          (delete-file link-file)
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
          (setq events nil)
          (write-region "hello" nil (expand-file-name "child.txt" tmpdir))
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
          (setq events nil)
          (write-region "hello" nil (expand-file-name "child.txt" tmpdir))
          (fsevents-tests--pump-events 1)
          (should-not events)
          (delete-file linkdir)
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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
          (fsevents-tests--pump-events 1)
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

(ert-deftest fsevents-test-file-rename-event ()
  "Renaming a watched file should generate one exact rename event."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (oldfile (expand-file-name "old.py" tmpdir))
         (newfile (expand-file-name "new.py" tmpdir))
         (events nil)
         (desc (fsevents-add-watch
                tmpdir '(create delete write attrib rename)
                (lambda (ev) (push ev events)))))
    (unwind-protect
        (progn
          (write-region "x = 1\n" nil oldfile)
          (fsevents-tests--pump-events 1)
          (setq events nil)
          (rename-file oldfile newfile)
          (fsevents-tests--pump-events 1)
          (should (cl-some (lambda (ev)
                             (and (memq 'rename (nth 1 ev))
                                  (equal oldfile (nth 2 ev))
                                  (equal newfile (nth 3 ev))))
                           events)))
      (fsevents-rm-watch desc)
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-rename-pair-across-shared-siblings ()
  "A rename inside one promoted sibling must not leak to another."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdirs (mapcar (lambda (n)
                            (expand-file-name (format "d%d" n) tmpdir))
                          (number-sequence 1 8)))
         (busy-dir (car subdirs))
         (quiet-dir (cadr subdirs))
         (oldfile (expand-file-name "old.py" busy-dir))
         (newfile (expand-file-name "new.py" busy-dir))
         (busy-events nil)
         (quiet-events nil)
         (descs nil)
         busy-desc quiet-desc)
    (dolist (dir subdirs)
      (make-directory dir))
    (write-region "x = 1\n" nil oldfile)
    (unwind-protect
        (progn
          (dolist (dir subdirs)
            (cond
             ((equal dir busy-dir)
              (setq busy-desc
                    (fsevents-add-watch
                     dir '(delete rename)
                     (lambda (ev) (push ev busy-events))))
              (push busy-desc descs))
             ((equal dir quiet-dir)
              (setq quiet-desc
                    (fsevents-add-watch
                     dir '(delete rename)
                     (lambda (ev) (push ev quiet-events))))
              (push quiet-desc descs))
             (t
              (push (fsevents-add-watch dir '(delete rename) #'ignore)
                    descs))))
          (should (= 1 (fsevents--debug-stream-count)))
          (should (= (fsevents--debug-watch-stream-id busy-desc)
                     (fsevents--debug-watch-stream-id quiet-desc)))
          (fsevents-tests--pump-events 1)
          (setq busy-events nil quiet-events nil)
          (rename-file oldfile newfile)
          (fsevents-tests--pump-events 1)
          (should (cl-some (lambda (ev)
                             (and (memq 'rename (nth 1 ev))
                                  (equal oldfile (nth 2 ev))
                                  (equal newfile (nth 3 ev))))
                           busy-events))
          (should-not quiet-events))
      (dolist (desc descs)
        (when (fsevents-valid-p desc)
          (fsevents-rm-watch desc)))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-same-path-trailing-slash-order ()
  "A synthetic rename batch reusing the same path (with and without a
trailing slash) must resolve in chronological order: create then
delete."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (path (expand-file-name "leaf" tmpdir))
         (path/ (concat path "/"))
         (events nil)
         (desc (fsevents-add-watch
                tmpdir '(create delete write attrib rename)
                (lambda (ev) (push ev events))))
         (sid (fsevents--debug-watch-stream-id desc)))
    (unwind-protect
        (progn
          (fsevents--debug-enqueue-rename-batch
           sid (list (list path nil) (list path/ nil)))
          (fsevents--debug-handle-pipe-ready)
          (fsevents-tests--pump-events 1)
          (setq events (cl-remove-if-not
                        (lambda (ev) (member (nth 2 ev) (list path path/)))
                        (nreverse events)))
          (should (equal (mapcar (lambda (ev) (car (nth 1 ev))) events)
                        '(create delete)))
          (should (equal path (nth 2 (nth 0 events))))
          (should (equal path/ (nth 2 (nth 1 events)))))
      (fsevents-rm-watch desc)
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-shared-one-sided-renames-stay-linear ()
  "A 200-entry one-sided rename batch shared by 8 promoted sibling
watches must resolve in a bounded number of pending-list probes."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (subdirs (mapcar (lambda (n)
                            (expand-file-name (format "d%d" n) tmpdir))
                          (number-sequence 1 8)))
         (busy-dir (car subdirs))
         (busy-events nil)
         (quiet-events nil)
         (descs nil)
         busy-desc sid)
    (dolist (dir subdirs)
      (make-directory dir))
    (unwind-protect
        (progn
          (dolist (dir subdirs)
            (if (equal dir busy-dir)
                (progn
                  (setq busy-desc
                        (fsevents-add-watch
                         dir '(delete rename)
                         (lambda (ev) (push ev busy-events))))
                  (push busy-desc descs))
              (push (fsevents-add-watch
                     dir '(delete rename)
                     (lambda (ev) (push ev quiet-events)))
                    descs)))
          (should (= 1 (fsevents--debug-stream-count)))
          (setq sid (fsevents--debug-watch-stream-id busy-desc))
          (fsevents-tests--pump-events 1)
          (setq busy-events nil quiet-events nil)
          (let ((entries
                 (mapcar (lambda (n)
                           (list (expand-file-name (format "f%d.py" n)
                                                    busy-dir)
                                 nil))
                         (number-sequence 0 199))))
            (fsevents--debug-reset-performance-counters)
            (fsevents--debug-enqueue-rename-batch sid entries)
            (fsevents--debug-handle-pipe-ready))
          (fsevents-tests--pump-events 1)
          (cl-destructuring-bind (prepares dispatches probes lstat-calls)
              (fsevents--debug-performance-counters)
            (should (= prepares 1))
            (should (= dispatches 8))
            (should (<= probes 3200))
            (should (= lstat-calls 0)))
          (should (= 200 (length busy-events)))
          (should (cl-every (lambda (ev) (memq 'delete (nth 1 ev)))
                            busy-events)))
          (should-not quiet-events)
      (dolist (desc descs)
        (when (fsevents-valid-p desc)
          (fsevents-rm-watch desc)))
      (delete-directory tmpdir t))))

(ert-deftest fsevents-test-non-rename-callback-does-not-lstat ()
  "A non-rename real filesystem event must not call lstat from the
GCD callback thread."
  (skip-unless fsevents-tests--available)
  (let* ((tmpdir (make-temp-file "fsevents-test" t))
         (testfile (expand-file-name "target.txt" tmpdir)))
    (write-region "x" nil testfile)
    (let* ((events nil)
           (desc (fsevents-add-watch
                  testfile '(write)
                  (lambda (ev) (push ev events)))))
      (unwind-protect
          (progn
            (fsevents-tests--pump-events 1)
            (fsevents--debug-reset-performance-counters)
            (write-region "x" nil testfile t 'silent)
            (fsevents-tests--pump-events 1)
            (should (cl-some (lambda (ev) (memq 'write (nth 1 ev))) events))
            (should (= 0 (nth 3 (fsevents--debug-performance-counters)))))
        (fsevents-rm-watch desc)
        (delete-directory tmpdir t)))))

;;; fsevents-tests.el ends here
