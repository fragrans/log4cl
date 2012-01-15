(in-package :log4cl)

(defmethod log-level-from-object (arg package)
  "Converts human readable log level description in ARG into numeric log level.

Supported values for ARG are:

- Symbol or string which name matches log level, e.g: :debug, :info,
  DEBUG, USER1, :err \"off\"

- 1-character long symbol or string, used as a shortcut. All standard
  levels can be uniquely identified by their first
  character: (o)ff (f)atal (e)rror (w)arn (i)nfo (d)ebug (t)race (u)nset,

- 1 character digit 1 through 9 identifying user1 through user9 levels." 
  (cond ((symbolp arg)
         (make-log-level (symbol-name arg)))
        ((stringp arg)
         (let ((len (length arg))
               match)
           (if (= 1 len)
               (setf match (position (char-upcase (char arg 0))
                                     +log-level-from-letter+))
               (let* ((name (string-upcase arg))
                      (len (length name)))
                 (loop 
                   for level from 0
                   for level-name in +log-level-from-string+
                   for tmp = (mismatch name level-name)
                   if (or (null tmp)
                          (= tmp len))
                   do (if match
                          (error "~s matches more then one log level" arg)
                          (setf match level)))))
           (or match 
               (error "~s does not match any log levels" arg))))
        ((and (numberp arg)
              (>= arg +min-log-level+)
              (<= arg +log-level-unset+))
         arg)
        (t (error "~s does not match any log levels" arg))))

#-sbcl
(defmethod resolve-default-logger-form (package env args)
  "Returns the logger named after the package by default"
  (values (get-logger (shortest-package-name package)) args))

(defun shortest-package-name (package)
  "Return the shortest name or nickname of the package"
  (let ((name (package-name package)))
    (dolist (nickname (package-nicknames package))
      (when (< (length nickname) (length name))
        (setq name nickname)))
    name))

#+sbcl 
(defun include-block-debug-name? (debug-name)
  "Figures out if we should include the debug-name into the stack of
nested blocks..  Should return the symbol to use.

For now SBCL seems to use:

  SYMBOL => normal defun block
  (LABELS SYMBOL) => inside of labels function
  (FLET SYMBOL)   => inside of flet function
  (LAMBDA (arglist) => inside of anonymous lambda
  (SB-PCL::FAST-METHOD SYMBOL ...) for defmethod
  (SB-PCL::VARARGS-ENTRY (SB-PCL::FAST-METHOD SYMBOL )) for defmethod with &rest parametwer
  (SB-C::HAIRY-ARG-PROCESSOR SYMBOL) => for functions with complex lambda lists

In all of the above cases except LAMBDA we simply return SYMBOL, for
LAMBDA we return the word LAMBDA and NIL for anything else.

Example: As a result of this default logger name for SBCL for the
following form:

   (defmethod foo ()
     (labels ((bar ()
                (funcall (lambda ()
                           (flet ((baz ()
                                    (log-info \"test\")))
                             (baz))))))
       (bar)))

will be: package.foo.bar.baz

"
  (if (symbolp debug-name)
      (when (and (not (member debug-name '(sb-c::.anonymous. 
                                           sb-thread::with-mutex-thunk)))
                 (not (scan "(?i)^cleanup-fun-" (symbol-name debug-name))))
        debug-name)
      (case (first debug-name)
        (labels (include-block-debug-name? (second debug-name)))
        (flet (include-block-debug-name? (second debug-name)))
        ;; (lambda 'lambda)
        (SB-PCL::FAST-METHOD (rest debug-name))
        (SB-C::HAIRY-ARG-PROCESSOR (include-block-debug-name? (second debug-name)))
        (SB-C::VARARGS-ENTRY (include-block-debug-name? (second debug-name))))))

#+sbcl
(defun sbcl-get-block-name  (env)
  "Return a list naming SBCL lexical environment. For example when
compiling local function FOO inside a global function FOOBAR, will
return \(FOOBAR FOO\)"
  (let* ((names
           (loop
             as lambda = (sb-c::lexenv-lambda env)
             then (sb-c::lambda-parent lambda)
             while lambda
             as debug-name = (include-block-debug-name? (sb-c::leaf-debug-name lambda))
             if debug-name collect debug-name)))
    (nreverse names)))

(defun join-categories (separator list)
  "Return a string with each element of LIST printed separated by
SEPARATOR"
  (let ((*print-pretty* nil)
        (*print-circle* nil))
    (with-output-to-string (s) 
      (princ (pop list) s)
      (dolist (elem list)
        (princ separator s)
        (princ elem s)))))

#+sbcl
(defmethod resolve-default-logger-form (package env args)
  "Returns the logger named after the current lexical environment"
  (values
   (get-logger
    (join-categories
     (naming-option package :category-separator)
     (cons (shortest-package-name package)
           (sbcl-get-block-name env))))
   args))

(defmethod naming-option (package option)
  "Return default values for naming options which are:
    :CATEGORY-SEPARATOR  #\\Colon
    :CATEGORY-CASE       :READTABLE
     "
  (declare (ignore package))
  (case option
    (:category-separator #\Colon)
    (:category-case :readtable)))

(defun logger-name-from-symbol (symbol env)
  "Return a logger name from a symbol."
  (declare (type keyword symbol) (ignore env))
  (format nil "~(~a~a~a~)"
          (shortest-package-name *package*)
          (naming-option *package* :category-separator)
          (symbol-name symbol)))

(defmethod resolve-logger-form (package env args)
  "- When first element of args is NIL or a constant string, calls
  RESOLVE-DEFAULT-LOGGER-FORM that will try to obtain logger name from
  the environment

- When first argument is a :KEYWORD, returns logger named <keyword>

- When first argument is a quoted symbol, returns logger named
  <current-package>.<symbol>

- Otherwise returns the form `(GET-LOGGER ,(FIRST ARGS) ,@(REST ARGS))'"
  (cond
    ((or (null args)
         (stringp (first args)))
     (resolve-default-logger-form package env args))
    ((keywordp (first args))
     (values (get-logger (logger-name-from-symbol (first args) env))
             (rest args)))
    ((constantp (first args))
     (let ((value (eval (first args))))
       (cond ((symbolp value)
              (get-logger (logger-name-from-symbol value env)))
             ((listp value)
              (get-logger
               (join-categories
                (naming-option package :category-separator) value)))
             (t (values (first args) (rest args))))))
    (t
     (values (first args) (rest args)))))

