;;; High-level compiler interface

;; Copyright (C) 2001 Free Software Foundation, Inc.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Code:

(define-module (system base compile)
  #:use-syntax (system base syntax)
  #:use-module (system base language)
  #:use-module (system il compile)
  #:use-module (system il glil)
  #:use-module (system vm objcode)
  #:use-module (system vm vm) ;; for compile-time evaluation
  #:use-module (system vm assemble)
  #:use-module (ice-9 regex)
  #:export (syntax-error compile-file load-source-file load-file
           compiled-file-name
           scheme-eval read-file-in compile-in
           load/compile))

;;;
;;; Compiler environment
;;;

(define (syntax-error loc msg exp)
  (throw 'syntax-error-compile-time loc msg exp))

(define-macro (call-with-compile-error-catch thunk)
  `(catch 'syntax-error-compile-time
	 ,thunk
	 (lambda (key loc msg exp)
	   (if (pair? loc)
	       (format (current-error-port)
                       "~A:~A: ~A: ~A~%" (car loc) (cdr loc) msg exp)
	       (format (current-error-port)
                       "unknown location: ~A: ~A~%" msg exp)))))

(export-syntax  call-with-compile-error-catch)



;;;
;;; Compiler
;;;

(define (scheme) (lookup-language 'scheme))

(define (call-with-output-file/atomic filename proc)
  (let* ((template (string-append filename ".XXXXXX"))
         (tmp (mkstemp! template)))
    (catch #t
           (lambda ()
             (with-output-to-port tmp
               (lambda () (proc (current-output-port))))
             (rename-file template filename))
           (lambda args
             (delete-file template)
             (apply throw args)))))

(define (compile-file file . opts)
  (let ((comp (compiled-file-name file))
        (scheme (scheme)))
    (catch 'nothing-at-all
      (lambda ()
	(call-with-compile-error-catch
	 (lambda ()
	   (call-with-output-file/atomic comp
	     (lambda (port)
	       (let* ((source (read-file-in file scheme))
		      (objcode (apply compile-in source (current-module)
				      scheme opts)))
		 (if (memq #:c opts)
		   (pprint-glil objcode port)
		   (uniform-vector-write (objcode->u8vector objcode) port)))))
	   (format #t "wrote `~A'\n" comp))))
      (lambda (key . args)
	(format #t "ERROR: during compilation of ~A:\n" file)
	(display "ERROR: ")
	(apply format #t (cadr args) (caddr args))
	(newline)
	(format #t "ERROR: ~A ~A ~A\n" key (car args) (cadddr args))
	(delete-file comp)))))

; (let ((c-f compile-file))
;   ;; XXX:  Debugging output
;   (set! compile-file
; 	(lambda (file . opts)
; 	  (format #t "compile-file: ~a ~a~%" file opts)
; 	  (let ((result (apply c-f (cons file opts))))
; 	    (format #t "compile-file: returned ~a~%" result)
; 	    result))))

(define (load-source-file file . opts)
  (let ((source (read-file-in file (scheme))))
    (apply compile-in source (current-module) (scheme) opts)))

(define (load-file file . opts)
  (let ((comp (compiled-file-name file)))
    (if (file-exists? comp)
	(load-objcode comp)
	(apply load-source-file file opts))))

(define (compiled-file-name file)
  (let ((base (basename file)))
    (let ((m (string-match "\\.scm$" base)))
      (string-append (if m (match:prefix m) base) ".go"))))

(define (scheme-eval x e)
  (vm-load (the-vm) (compile-in x e (scheme))))


;;;
;;; Scheme compiler interface
;;;

(define (read-file-in file lang)
  (call-with-input-file file (language-read-file lang)))

(define (compile-in x e lang . opts)
  (save-module-excursion
   (lambda ()
     (catch 'result
      (lambda ()
        ;; expand
        (set! x ((language-expander lang) x e))
        (if (memq #:e opts) (throw 'result x))
        ;; translate
        (set! x ((language-translator lang) x e))
        (if (memq #:t opts) (throw 'result x))
        ;; compile
        (set! x (apply compile x e opts))
        (if (memq #:c opts) (throw 'result x))
        ;; assemble
        (apply assemble x e opts))
      (lambda (key val) val)))))

;;;
;;;
;;;

(define (compile-and-load file . opts)
  (let ((comp (object-file-name file)))
    (if (or (not (file-exists? comp))
	    (> (stat:mtime (stat file)) (stat:mtime (stat comp))))
	(compile-file file))
    (load-compiled-file comp)))

(define (load/compile file . opts)
  (let* ((file (file-full-name file))
	 (compiled (object-file-name file)))
    (if (or (not (file-exists? compiled))
	    (> (stat:mtime (stat file)) (stat:mtime (stat compiled))))
	(apply compile-file file #f opts))
    (if (memq #:b opts)
	(apply vm-trace (the-vm) (load-objcode compiled) opts)
	((the-vm) (load-objcode compiled)))))

(define (file-full-name filename)
  (let* ((port (current-load-port))
	 (oldname (and port (port-filename port))))
    (if (and oldname
	     (> (string-length filename) 0)
	     (not (char=? (string-ref filename 0) #\/))
	     (not (string=? (dirname oldname) ".")))
	(string-append (dirname oldname) "/" filename)
	filename)))