;;; Haunt --- Static site generator for GNU Guile
;;; Copyright © 2015 David Thompson <davet@gnu.org>
;;;
;;; This file is part of Haunt.
;;;
;;; Haunt is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; Haunt is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with Haunt.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Simple HTTP server.
;;
;;; Code:

(define-module (haunt serve web-server)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (sxml simple)
  #:use-module (web server)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (haunt serve mime-types)
  #:export (serve))

(define (stat:directory? stat)
  "Return #t if STAT is a directory."
  (eq? (stat:type stat) 'directory))

(define (directory? file-name)
  "Return #t if FILE-NAME is a directory."
  (stat:directory? (stat file-name)))

(define (directory-contents dir)
  "Return a list of the files contained within DIR."
  (define name+directory?
    (match-lambda
     ((name stat)
      (list name (stat:directory? stat)))))

  (define (same-dir? other stat)
    (string=? dir other))

  (match (file-system-tree dir same-dir?)
    ;; We are not interested in the parent directory, only the
    ;; children.
    ((_ _ children ...)
     (map name+directory? children))))

(define (work-dir+path->file-name work-dir path)
  "Convert the URI PATH to an absolute file name relative to the
directory WORK-DIR."
  (string-append work-dir path))

(define (resolve-file-name file-name)
  "If FILE-NAME is a directory with an 'index.html' file,
return that file name.  If FILE-NAME does not exist, return #f.
Otherwise, return FILE-NAME as-is."
  (let ((index-file-name (string-append file-name "/index.html")))
    (cond
     ((file-exists? index-file-name) index-file-name)
     ((file-exists? file-name) file-name)
     (else #f))))

(define (dump-file file-name port)
  "Write the contents of FILE-NAME to PORT."
  (with-input-from-file file-name
    (lambda ()
      (let loop ((char (read-char)))
        (unless (eof-object? char)
          (write-char char port)
          (loop (read-char)))))))

(define (render-file file-name)
  "Return a 200 OK HTTP response that renders the contents of
FILE-NAME."
  (values `((content-type . (,(mime-type file-name))))
          (lambda (port)
            (dump-file file-name port))))

(define (render-directory path dir)
  "Render the contents of DIR represented by the URI PATH."
  (define render-child
    (match-lambda
     ((file-name directory?)
      `(li
        (a (@ (href ,(string-append path "/" file-name)))
           ,(if directory?
                (string-append file-name "/")
                file-name))))))

  (define file-name<
    (match-lambda*
     (((name-a _) (name-b _))
      (string< name-a name-b))))

  (let* ((children (sort (directory-contents dir) file-name<))
         (title (string-append "Directory listing for " path))
         (view `(html
                (head
                 (title ,title))
                (body
                 (h1 ,title)
                 (h2 "<i>foobar</i>")
                 (ul ,@(map render-child children))))))
    (values '((content-type . (text/html)))
            (lambda (port)
              (display "<!DOCTYPE html>" port)
              (sxml->xml view port)))))

(define (not-found path)
  "Return a 404 not found HTTP response for PATH."
  (values (build-response #:code 404)
          (string-append "Resource not found: " path)))

(define (serve-file work-dir path)
  "Return an HTTP response for the file represented by PATH."
  (match (resolve-file-name
          (work-dir+path->file-name work-dir path))
    (#f (not-found path))
    ((? directory? dir)
     (render-directory path dir))
    (file-name
     (render-file file-name))))

(define (make-handler work-dir)
  (lambda (request body)
    "Serve the file asked for in REQUEST."
    (let ((path (uri-path (request-uri request))))
      (format #t "~a ~a~%" (request-method request) path)
      (serve-file work-dir path))))

(define* (serve work-dir #:key (open-params '()))
  "Run a simple HTTP server that serves files in WORK-DIR."
  (run-server (make-handler work-dir) 'http open-params))