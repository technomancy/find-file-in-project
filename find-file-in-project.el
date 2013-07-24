;;; find-file-in-project.el --- Find files in a project quickly.

;; Copyright (C) 2006-2009, 2011-2012
;;   Phil Hagelberg, Doug Alcorn, and Will Farrington

;; Author: Phil Hagelberg, Doug Alcorn, and Will Farrington
;; URL: http://www.emacswiki.org/cgi-bin/wiki/FindFileInProject
;; Git: git://github.com/technomancy/find-file-in-project.git
;; Version: 3.2
;; Created: 2008-03-18
;; Keywords: project, convenience
;; EmacsWiki: FindFileInProject

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This library provides a couple methods for quickly finding any file
;; in a given project.  It depends on GNU find.

;; A project is found by searching up the directory tree until a file
;; is found that matches `ffip-project-file'.  (".git" by default.)
;; You can set `ffip-project-root-function' to provide an alternate
;; function to search for the project root.  By default, it looks only
;; for files whose names match `ffip-patterns',

;; If you have so many files that it becomes unwieldy, you can set
;; `ffip-find-options' to a string which will be passed to the `find'
;; invocation in order to exclude irrelevant subdirectories.  For
;; instance, in a Ruby on Rails project, you may be interested in all
;; .rb files that don't exist in the "vendor" directory.  In that case
;; you could set `ffip-find-options' to "-not -regex \".*vendor.*\"".

;; All these variables may be overridden on a per-directory basis in
;; your .dir-locals.el.  See (info "(Emacs) Directory Variables") for
;; details.

;; Recommended binding: (global-set-key (kbd "C-x f") 'find-file-in-project)

;;; TODO:

;; Add compatibility with BSD find (PDI; I can't virtualize OS X)

;;; Code:

(require 'cl)

(defvar ffip-project-file ".git"
  "The file that should be used to define a project root.

May be set using .dir-locals.el. Checks each entry if set to a list.")

(defvar ffip-patterns
  '("*.html" "*.org" "*.txt" "*.md" "*.el" "*.clj" "*.py" "*.rb" "*.js" "*.pl"
    "*.sh" "*.erl" "*.hs" "*.ml")
  "List of patterns to look for with `find-file-in-project'.")

(defvar ffip-find-options ""
  "Extra options to pass to `find' when using `find-file-in-project'.

Use this to exclude portions of your project: \"-not -regex \\\".*svn.*\\\"\".")

(defvar ffip-project-root nil
  "If non-nil, overrides the project root directory location.")

(defvar ffip-project-root-function nil
  "If non-nil, this function is called to determine the project root.

This overrides variable `ffip-project-root' when set.")

(defvar ffip-limit 512
  "Limit results to this many files.")

(defvar ffip-full-paths nil
  "If non-nil, show fully project-relative paths.")

(defun ffip-trim-string (string)
  "Trims leading and trailing whitespace from a string"
  (replace-regexp-in-string "[\t\n ]" "" string))

(defun ffip-file-contents (file-path)
  "Returns the contents of a file as a string or nil"
  (let* ((buffer-name "ffip")
         (buffer (get-buffer-create buffer-name))
         (content (if (file-exists-p file-path)
                      (save-excursion
                        (set-buffer buffer)
                        (insert-file-contents file-path)
                        (message "content: %s" (buffer-substring (point-min) (point-max)))
                        (buffer-substring (point-min) (point-max)))
                    nil)))
    (message "%s %s" file-path (file-exists-p file-path))
    (kill-buffer buffer)
    content))

(defun ffip-project-head (root)
  "If the profect root is a git repository returns the sha of HEAD"
  (let* ((head-file-path (format "%s/.git/HEAD" root))
         (ref-mapping (ffip-file-contents head-file-path))
         (ref (ffip-trim-string (nth 1 (split-string ref-mapping ": " t))))
         (ref-file-path (format "%s/.git/%s" root ref))
         (hash (ffip-trim-string ffip-file-contents ref-file-path)))
    hash))

(defun ffip-project-head (root)
  "If the profect root is a git repository returns the sha of HEAD"
  (let* ((buffer-name "ffip")
         (buffer (get-buffer-create buffer-name))
         (head-file-name (format "%s/.git/HEAD" root))
         (hash (if (file-exists-p head-file-name)
                   (save-excursion
                     (set-buffer buffer)
                     (insert-file-contents head-file-name)
                     (let* ((ref-mapping (buffer-substring
                                          (point-min) (point-max)))
                            (ref (ffip-trim-string
                                  (nth 1 (split-string ref-mapping ": " t))))
                            (ref-file-name (format "%s/.git/%s" root ref)))
                       (erase-buffer)
                       (insert-file-contents ref-file-name)
                       (ffip-trim-string (buffer-substring
                                          (point-min) (point-max)))))
                 nil)))
    (kill-buffer buffer)
    hash))

(defvar ffip-project-file-cache (make-hash-table :test 'equal)
  "A cache of project files keyed by project head")

(defvar ffip-project-head-cache (make-hash-table :test 'equal)
  "A cache of the project heads by project root. Used to
  invalidate stale entries in ffip-project-file-cache")

(defun ffip-lookup-project-head (root)
  "Lookup the head for a given project root"
  (gethash root ffip-project-head-cache nil))

(defun ffip-lookup-project-files (root)
  "Lookup the project files for a given project root"
  (let* ((head (ffip-lookup-project-head root))
         (current-head (ffip-project-head root))
         (files (if (and head (string= head current-head))
                    (gethash head ffip-project-file-cache nil)
                  (progn (remhash root ffip-project-head-cache)
                         (remhash head ffip-project-file-cache)
                         nil))))
    files))

(defun ffip-update-project-files (root files)
  "Update the list of project files for a given project root"
  (let ((head (or (ffip-lookup-project-head root)
                  (ffip-project-head root))))
    (if head
        (progn (puthash root head ffip-project-head-cache)
               (puthash head files ffip-project-file-cache)
               (message "Updated project file cache for %s %s" root head)))))

(defun ffip-project-root ()
  "Return the root of the project."
  (let ((project-root (or ffip-project-root
                          (if (functionp ffip-project-root-function)
                              (funcall ffip-project-root-function)
                            (if (listp ffip-project-file)
                                (some (apply-partially 'locate-dominating-file
                                                       default-directory)
                                      ffip-project-file)
                              (locate-dominating-file default-directory
                                                      ffip-project-file))))))
    (or project-root
        (progn (message "No project was defined for the current file.")
               nil))))

(defun ffip-uniqueify (file-cons)
  "Set the car of FILE-CONS to include the directory name plus the file name."
  (setcar file-cons
          (concat (cadr (reverse (split-string (cdr file-cons) "/"))) "/"
                  (car file-cons))))

(defun ffip-join-patterns ()
  "Turn `ffip-paterns' into a string that `find' can use."
  (mapconcat (lambda (pat) (format "-name \"%s\"" pat))
             ffip-patterns " -or "))

(defun ffip-project-files ()
  "Return an alist of all filenames in the project and their path.

Files with duplicate filenames are suffixed with the name of the
directory they are found in so that they are unique."
  (let* ((file-alist nil)
         (root (expand-file-name (or ffip-project-root (ffip-project-root)
                                     (error "No project root found"))))
         (files (or (ffip-lookup-project-files root)
                    (mapcar (lambda (file)
                              (if ffip-full-paths
                                  (cons (substring (expand-file-name file)
                                                   (length root))
                                        (expand-file-name file))
                                (let ((file-cons (cons (file-name-nondirectory
                                                        file)
                                                       (expand-file-name
                                                        file))))
                                  (when (assoc (car file-cons) file-alist)
                                    (ffip-uniqueify (assoc (car file-cons)
                                                           file-alist))
                                    (ffip-uniqueify file-cons))
                                  (add-to-list 'file-alist file-cons)
                                  file-cons)))
                            (split-string (shell-command-to-string
                                           (format
                                            "find %s -type f \\( %s \\) %s | head -n %s"
                                            root (ffip-join-patterns)
                                            ffip-find-options ffip-limit)))))))
    (ffip-update-project-files root files)
    files))

;;;###autoload
(defun find-file-in-project ()
  "Prompt with a completing list of all files in the project to find one.

The project's scope is defined as the first directory containing
an `.emacs-project' file.  You can override this by locally
setting the variable `ffip-project-root'."
  (interactive)
  (let* ((project-files (ffip-project-files))
         (files (mapcar 'car project-files))
         (file (if (and (boundp 'ido-mode) ido-mode)
                   (ido-completing-read "Find file in project: " files)
                 (completing-read "Find file in project: " files))))
    (find-file (cdr (assoc file project-files)))))

;;;###autoload
(defalias 'ffip 'find-file-in-project)

;; safe locals
;;;###autoload
(progn
  (put 'ffip-patterns 'safe-local-variable 'listp)
  (put 'ffip-find-options 'safe-local-variable 'stringp)
  (put 'ffip-project-file 'safe-local-variable 'stringp)
  (put 'ffip-project-root 'safe-local-variable 'stringp)
  (put 'ffip-project-root-function 'safe-local-variable 'functionp)
  (put 'ffip-limit 'safe-local-variable 'integerp))

(provide 'find-file-in-project)
;;; find-file-in-project.el ends here
