;;; slime-parse.el --- parsing of Common Lisp source code
;;
;; Authors: Matthias Koeppe  <mkoeppe@mail.math.uni-magdeburg.de>
;;          Tobias C. Rittweiler <tcr@freebits.de>
;;          and others
;; 
;; License: GNU GPL (same license as Emacs)
;;

(defun slime-incomplete-form-at-point ()
  (slime-make-form-spec-from-string
   (concat (slime-incomplete-sexp-at-point) ")")))

(defun slime-parse-sexp-at-point (&optional n)
  "Returns the sexps at point as a list of strings, otherwise nil.
\(If there are not as many sexps as N, a list with < N sexps is
returned.\) 
If SKIP-BLANKS-P is true, leading whitespaces &c are skipped.
"
  (interactive "p") (or n (setq n 1))
  (save-excursion
    (let ((result nil))
      (dotimes (i n)
        ;; Is there an additional sexp in front of us?
        (save-excursion
          (unless (slime-point-moves-p (ignore-errors (forward-sexp)))
            (return)))
        (push (slime-sexp-at-point) result)
        ;; Skip current sexp
        (ignore-errors (forward-sexp) (skip-chars-forward "[:space:]")))
      (nreverse result))))

(defun slime-has-symbol-syntax-p (string)
  (if (and string (not (zerop (length string))))
      (member (char-syntax (aref string 0)) 
	      '(?w ?_ ?\' ?\\))))

(defun slime-incomplete-sexp-at-point (&optional n)
  (interactive "p") (or n (setq n 1))
  (buffer-substring-no-properties 
   (save-excursion (backward-up-list n) (point))
   (point)))


(defun slime-parse-extended-operator-name (user-point forms indices points)
  "Assume that point is directly at the operator that should be parsed.
USER-POINT is the value of `point' where the user was looking at.
OPS, INDICES and POINTS are updated to reflect the new values after
parsing, and are then returned back as multiple values."
  ;; OPS, INDICES and POINTS are like the finally returned values of
  ;; SLIME-ENCLOSING-FORM-SPECS except that they're in reversed order,
  ;; i.e. the leftmost operator comes first.
  (save-excursion
    (ignore-errors
      (let* ((current-op (first (first forms)))
             (op-name (upcase (slime-cl-symbol-name current-op)))
             (assoc (assoc op-name slime-extended-operator-name-parser-alist))
             (entry (cdr assoc))
             (parser (if (and entry (listp entry)) 
                         (apply (first entry) (rest entry))
                         entry)))
        (ignore-errors
          (forward-char (1+ (length current-op)))
          (skip-chars-forward "[:space:]"))
        (when parser
          (multiple-value-setq (forms indices points)
            ;; We pass the fully qualified name (`current-op'), so it's the
            ;; fully qualified name that will be sent to SWANK.
            (funcall parser current-op user-point forms indices points))))))
  (values forms indices points))


(defvar slime-extended-operator-name-parser-alist
  '(("MAKE-INSTANCE"  . (slime-make-extended-operator-parser/look-ahead 1))
    ("MAKE-CONDITION" . (slime-make-extended-operator-parser/look-ahead 1))
    ("ERROR"          . (slime-make-extended-operator-parser/look-ahead 1))
    ("SIGNAL"         . (slime-make-extended-operator-parser/look-ahead 1))
    ("WARN"           . (slime-make-extended-operator-parser/look-ahead 1))
    ("CERROR"         . (slime-make-extended-operator-parser/look-ahead 2))
    ("CHANGE-CLASS"   . (slime-make-extended-operator-parser/look-ahead 2))
    ("DEFMETHOD"      . (slime-make-extended-operator-parser/look-ahead 1))
    ("DEFINE-COMPILER-MACRO" . (slime-make-extended-operator-parser/look-ahead 1))
    ("APPLY"          . (slime-make-extended-operator-parser/look-ahead 1))
    ("DECLARE"        . slime-parse-extended-operator/declare)
    ("DECLAIM"        . slime-parse-extended-operator/declare)
    ("PROCLAIM"       . slime-parse-extended-operator/proclaim)
    ("CHECK-TYPE"     . slime-parse-extended-operator/check-type)
    ("TYPEP"          . slime-parse-extended-operator/check-type)
    ("THE"            . slime-parse-extended-operator/the)))


(defun slime-make-extended-operator-parser/look-ahead (steps)
  "Returns a parser that parses the current operator at point
plus (at most) STEPS-many additional sexps on the right side of
the operator."
  (lexical-let ((n steps))
    #'(lambda (name user-point current-forms current-indices current-points)
        (let ((old-forms (rest current-forms))
              (arg-idx   (first current-indices)))
          (when (and (not (zerop arg-idx)) ; point is at CAR of form?
                     (not (= (point)       ; point is at end of form?
                             (save-excursion
                               (ignore-errors (slime-end-of-list))
                               (point)))))
            (let* ((args (slime-parse-sexp-at-point n))
                   (arg-specs (mapcar #'slime-make-form-spec-from-string args)))
              (setq current-forms (cons `(,name ,@arg-specs) old-forms))))
          (values current-forms current-indices current-points)))))

;;; FIXME: We display "(proclaim (optimize ...))" instead of the
;;; correct "(proclaim '(optimize ...))".
(defun slime-parse-extended-operator/proclaim (&rest args)
  (when (looking-at "['`]")
    (forward-char)
    (apply #'slime-parse-extended-operator/declare args)))

(defun slime-parse-extended-operator/declare
    (name user-point current-forms current-indices current-points)
  (when (looking-at "(")
    (goto-char user-point)
    (slime-end-of-symbol)
    ;; Head of CURRENT-FORMS is "declare" (or similiar) at this
    ;; point, but we're interested in what comes next.
    (let* ((decl-indices (rest current-indices))
           (decl-points  (rest current-points))
           (decl-pos     (1- (first decl-points)))
           (nesting      (slime-nesting-until-point decl-pos))
           (declspec-str (concat (slime-incomplete-sexp-at-point nesting)
                                 (make-string nesting ?\)))))
      (save-match-data ; `(declare ((foo ...))' or `(declare (type (foo ...)))' ?
        (if (or (eql 0 (string-match "\\s-*(\\((\\(\\sw\\|\\s_\\|\\s-\\)*)\\))$"
                                     declspec-str))
                (eql 0 (string-match "\\s-*(type\\s-*\\((\\(\\sw\\|\\s_\\|\\s-\\)*)\\))$"
                                     declspec-str)))
            (let* ((typespec-str (match-string 1 declspec-str))
                   (typespec (slime-make-form-spec-from-string typespec-str)))
              (setq current-forms   (list `(:type-specifier ,typespec)))
              (setq current-indices (list (second decl-indices)))
              (setq current-points  (list (second decl-points))))
            (let ((declspec (slime-make-form-spec-from-string declspec-str)))
              (setq current-forms   (list `(,name) `(:declaration ,declspec)))
              (setq current-indices (list (first current-indices)
                                          (first decl-indices)))
              (setq current-points  (list (first current-points)
                                          (first decl-points))))))))
  (values current-forms current-indices current-points))

(defun slime-parse-extended-operator/check-type
    (name user-point current-forms current-indices current-points)
  (let ((arg-idx        (first current-indices))
        (typespec       (second current-forms))
        (typespec-start (second current-points)))
    (when (and (eql 2 arg-index)
               typespec                   ; `(check-type ... (foo |' ?
               (if (equalp name "typep")  ; `(typep ... '(foo |' ?
                   (progn (goto-char (- typespec-start 2))
                          (looking-at "['`]"))
                   t))
        ;; compound types VALUES and FUNCTION are not allowed in TYPEP
        ;; (and consequently CHECK-TYPE.)
        (unless (member (first typespec) '("values" "function"))
          (setq current-forms   `((:type-specifier ,typespec)))
          (setq current-indices (rest current-indices))
          (setq current-points  (rest current-points))))
    (values current-forms current-indices current-points)))

(defun slime-parse-extended-operator/the
    (name user-point current-forms current-indices current-points)
  (let ((arg-idx  (first current-indices))
        (typespec (second current-forms)))
    (if (and (eql 1 arg-idx) typespec)  ; `(the (foo |' ?
        (values `((:type-specifier ,typespec))
                (rest current-indices)
                (rest current-points))
        (values current-forms current-indices current-points))))



(defun slime-nesting-until-point (target-point)
  "Returns the nesting level between current point and TARGET-POINT.
If TARGET-POINT could not be reached, 0 is returned. (As a result
TARGET-POINT should always be placed just before a `?\('.)"
  (save-excursion
    (let ((nesting 0))
      (while (> (point) target-point)
        (backward-up-list)
        (incf nesting))
      (if (= (point) target-point)
          nesting
          0))))

(defun slime-make-form-spec-from-string (string &optional strip-operator-p)
  "Example: \"(foo (bar 1 (baz :quux)) 'toto)\" 

            => (\"foo\" (\"bar\" \"1\" (\"baz\" \":quux\")) \"'toto\")"
  (cond ((slime-length= string 0) "")                    ; ""
	((equal string "()") '())                        ; "()"
	((eql (char-syntax (aref string 0)) ?\') string) ; "'(foo)", "#(foo)" &c
	((not (eql (aref string 0) ?\()) string)         ; "foo"
	(t                                               ; "(op arg1 arg2 ...)"
         (with-current-buffer (get-buffer-create " *slime-make-form-spec-buffer*")
           ;; Do NEVER ever try to activate `lisp-mode' here with
           ;; `slime-use-autodoc-mode' enabled, as this function is used
           ;; to compute the current autodoc itself.
           (set-syntax-table lisp-mode-syntax-table)
           (erase-buffer)
           (insert string)
           (goto-char (1+ (point-min)))
           (let ((subsexps)
                 (end))
             (while (condition-case nil 
                        (slime-point-moves-p (slime-forward-sexp))
                      (scan-error nil)  ; can't move any further
                      (error t))        ; unknown feature expression etc.
               ;; We first move back for (FOO)'BAR where point is at
               ;; the quote character.
               (setq end (point))               
               (push (buffer-substring-no-properties 
                      (save-excursion (backward-sexp) (point)) 
                      end) 
                     subsexps))
             (mapcar #'(lambda (s)
                         (assert (not (equal s string)))      
                         (slime-make-form-spec-from-string s))
                     (nreverse subsexps)))))))

;;; TODO: With the rewrite of autodoc, this function like pretty much
;;; everything else in this file, is obsolete.

(defun slime-enclosing-form-specs (&optional max-levels)
  "Return the list of ``raw form specs'' of all the forms 
containing point from right to left.

As a secondary value, return a list of indices: Each index tells
for each corresponding form spec in what argument position the
user's point is.

As tertiary value, return the positions of the operators that are
contained in the returned form specs. 

When MAX-LEVELS is non-nil, go up at most this many levels of
parens.

\(See SWANK::PARSE-FORM-SPEC for more information about what
exactly constitutes a ``raw form specs'')

Examples:

  A return value like the following

    (values  ((\"quux\") (\"bar\") (\"foo\")) (3 2 1) (p1 p2 p3))

  can be interpreted as follows:

    The user point is located in the 3rd argument position of a
    form with the operator name \"quux\" (which starts at P1.)
   
    This form is located in the 2nd argument position of a form
    with the operator name \"bar\" (which starts at P2.)

    This form again is in the 1st argument position of a form
    with the operator name \"foo\" (which itself begins at P3.)

  For instance, the corresponding buffer content could have looked
  like `(foo (bar arg1 (quux 1 2 |' where `|' denotes point.
"
  (let ((level 1)
        (parse-sexp-lookup-properties nil)
        (initial-point (point))
        (result '()) (arg-indices '()) (points '())) 
    ;; The expensive lookup of syntax-class text properties is only
    ;; used for interactive balancing of #<...> in presentations; we
    ;; do not need them in navigating through the nested lists.
    ;; This speeds up this function significantly.
    (ignore-errors
      (save-excursion
        ;; Make sure we get the whole thing at point.
        (if (not (slime-inside-string-p))
            (slime-end-of-symbol)
          (slime-beginning-of-string)
          (forward-sexp))
        (save-restriction
          ;; Don't parse more than 20000 characters before point, so we don't spend
          ;; too much time.
          (narrow-to-region (max (point-min) (- (point) 20000)) (point-max))
          (narrow-to-region (save-excursion (beginning-of-defun) (point))
                            (min (1+ (point)) (point-max)))
          (while (or (not max-levels)
                     (<= level max-levels))
            (let ((arg-index 0))
              ;; Move to the beginning of the current sexp if not already there.
              (if (or (and (char-after)
                           (member (char-syntax (char-after)) '(?\( ?')))
                      (member (char-syntax (char-before)) '(?\  ?>)))
                  (incf arg-index))
              (ignore-errors (backward-sexp 1))
              (while (and (< arg-index 64)
                          (ignore-errors (backward-sexp 1) 
                                         (> (point) (point-min))))
                (incf arg-index))
              (backward-up-list 1)
              (when (member (char-syntax (char-after)) '(?\( ?')) 
                (incf level)
                (forward-char 1)
                (let ((name (slime-symbol-at-point)))
                  (cond
                    (name
                     (save-restriction
                       (widen) ; to allow looking-ahead/back in extended parsing.
                       (multiple-value-bind (new-result new-indices new-points)
                           (slime-parse-extended-operator-name 
                            initial-point
                            (cons `(,name) result) ; minimal form spec
                            (cons arg-index arg-indices)
                            (cons (point) points))
                         (setq result new-result)
                         (setq arg-indices new-indices)
                         (setq points new-points))))
                    (t
                     (push nil result)
                     (push arg-index arg-indices)
                     (push (point) points))))
                (backward-up-list 1)))))))
    (values 
     (nreverse result)
     (nreverse arg-indices)
     (nreverse points))))

(defun slime-parse-form-until (limit form-suffix)
  "Parses form from point to `limit'."
  ;; For performance reasons, this function does not use recursion.
  (let ((todo (list (point))) ; stack of positions
        (sexps)               ; stack of expressions
        (cursexp)
        (curpos)
        (depth 1))            ; This function must be called from the
                              ; start of the sexp to be parsed.
    (while (and (setq curpos (pop todo))
                (progn
                  (goto-char curpos)
                  ;; (Here we also move over suppressed
                  ;; reader-conditionalized code! Important so CL-side
                  ;; of autodoc won't see that garbage.)
                  (ignore-errors (slime-forward-cruft))
                  (< (point) limit)))
      (setq cursexp (pop sexps))
      (cond
        ;; End of an sexp?
        ((or (looking-at "\\s)") (eolp))
         (decf depth)
         (push (nreverse cursexp) (car sexps)))
        ;; Start of a new sexp?
        ((looking-at "\\s'?\\s(")
         (let ((subpt (match-end 0)))
           (ignore-errors
             (forward-sexp)
             ;; (In case of error, we're at an incomplete sexp, and
             ;; nothing's left todo after it.)
             (push (point) todo))
           (push cursexp sexps)
           (push subpt todo)            ; to descend into new sexp
           (push nil sexps)
           (incf depth)))
        ;; In mid of an sexp..
        (t
         (let ((pt1 (point))
               (pt2 (condition-case e
                        (progn (forward-sexp) (point))
                      (scan-error
                       (fourth e)))))   ; end of sexp
           (push (buffer-substring-no-properties pt1 pt2) cursexp)
           (push pt2 todo)
           (push cursexp sexps)))))
    (when sexps
      (setf (car sexps) (nreconc form-suffix (car sexps)))
      (while (> depth 1)
        (push (nreverse (pop sexps)) (car sexps))
        (decf depth))
      (nreverse (car sexps)))))

(defun slime-compare-char-syntax (get-char-fn syntax &optional unescaped)
  "Returns t if the character that `get-char-fn' yields has
characer syntax of `syntax'. If `unescaped' is true, it's ensured
that the character is not escaped."
  (let ((char        (funcall get-char-fn (point)))
	(char-before (funcall get-char-fn (1- (point)))))
    (if (and char (eq (char-syntax char) (aref syntax 0)))
	(if unescaped
	    (or (null char-before)
		(not (eq (char-syntax char-before) ?\\)))
	    t)
        nil)))

(defconst slime-cursor-marker 'swank::%cursor-marker%)

(defun slime-parse-form-upto-point (&optional max-levels)
  (save-restriction
    ;; Don't parse more than 500 lines before point, so we don't spend
    ;; too much time. NB. Make sure to go to beginning of line, and
    ;; not possibly anywhere inside comments or strings.
    (narrow-to-region (line-beginning-position -500) (point-max))
    (save-excursion
      (let ((suffix (list slime-cursor-marker)))
        (cond ((slime-compare-char-syntax #'char-after "(" t)
               ;; We're at the start of some expression, so make sure
               ;; that SWANK::%CURSOR-MARKER% will come after that
               ;; expression.
               (ignore-errors (forward-sexp)))
              ((or (bolp) (slime-compare-char-syntax #'char-before " " t))
               ;; We're after some expression, so we have to make sure
               ;; that %CURSOR-MARKER% does not come directly after that
               ;; expression.
               (push "" suffix))
              ((slime-compare-char-syntax #'char-before "(" t)
               ;; We're directly after an opening parenthesis, so we
               ;; have to make sure that something comes before
               ;; %CURSOR-MARKER%.
               (push "" suffix))
              (t
               ;; We're at a symbol, so make sure we get the whole symbol.
               (slime-end-of-symbol)))
        (let ((pt (point)))
          (ignore-errors (up-list (if max-levels (- max-levels) -5)))
          (ignore-errors (down-list))
          (slime-parse-form-until pt suffix))))))

(defun slime-ensure-list (thing)
  (if (listp thing) thing (list thing)))

(defun slime-beginning-of-string ()
  (let* ((parser-state (slime-current-parser-state))
	 (inside-string-p  (nth 3 parser-state))
	 (string-start-pos (nth 8 parser-state)))
    (if inside-string-p
        (goto-char string-start-pos)
        (error "We're not within a string"))))


;;;; Test cases

(defun slime-check-enclosing-form-specs (wished-form-specs)
  (slime-test-expect 
   (format "Enclosing form specs correct in `%s' (at %d)" (buffer-string) (point))
   wished-form-specs
   (first (slime-enclosing-form-specs))))

(def-slime-test enclosing-form-specs.1
    (buffer-sexpr wished-form-specs)
    "Check that we correctly determine enclosing forms."
    '(("(defun *HERE*"                  (("defun")))
      ("(defun foo *HERE*"              (("defun")))
      ("(defun foo (x y) *HERE*"        (("defun")))
      ("(defmethod *HERE*"              (("defmethod")))
      ("(defmethod foo *HERE*"          (("defmethod" "foo")))
      ("(cerror foo *HERE*"             (("cerror" "foo")))
      ("(cerror foo bar *HERE*"         (("cerror" "foo" "bar")))
      ("(make-instance foo *HERE*"      (("make-instance" "foo")))
      ("(apply 'foo *HERE*"             (("apply" "'foo")))
      ("(apply #'foo *HERE*"            (("apply" "#'foo")))
      ("(declare *HERE*"                (("declare")))
      ("(declare (optimize *HERE*"      ((:declaration ("optimize")) ("declare")))
      ("(declare (string *HERE*"        ((:declaration ("string")) ("declare")))
      ("(declare ((vector *HERE*"       ((:type-specifier ("vector"))))
      ("(declare ((vector bit *HERE*"   ((:type-specifier ("vector" "bit"))))
      ("(proclaim '(optimize *HERE*"    ((:declaration ("optimize")) ("proclaim")))
      ("(the (string *HERE*"            ((:type-specifier ("string"))))
      ("(check-type foo (string *HERE*" ((:type-specifier ("string"))))
      ("(typep foo '(string *HERE*"     ((:type-specifier ("string")))))
  (slime-check-top-level)
  (with-temp-buffer
    (lisp-mode)
    (insert buffer-sexpr)
    (search-backward "*HERE*")
    (delete-region (match-beginning 0) (match-end 0))
    (slime-check-enclosing-form-specs wished-form-specs)
    (insert ")") (backward-char)
    (slime-check-enclosing-form-specs wished-form-specs)      
    ))

(defun slime-check-buffer-form (result-form)
  (slime-test-expect 
   (format "Buffer form correct in `%s' (at %d)" (buffer-string) (point))
   result-form
   (slime-parse-form-upto-point 10)))

(def-slime-test form-up-to-point.1
    (buffer-sexpr result-form)
    ""
    '(("(char= #\\(*HERE*"            ("char=" "#\\(" swank::%cursor-marker%))
      ("(char= #\\( *HERE*"           ("char=" "#\\(" "" swank::%cursor-marker%))
      ("(char= #\\) *HERE*"           ("char=" "#\\)" "" swank::%cursor-marker%))
                                      ;; The #\) here is an accident of 
                                      ;; the implementation.
      ("(char= #\\*HERE*"             ("char=" "#\\)" swank::%cursor-marker%))
      ("(defun*HERE*"                 ("defun" swank::%cursor-marker%))
      ("(defun foo*HERE*"             ("defun" "foo" swank::%cursor-marker%))
      ("(defun foo (x y)*HERE*"       ("defun" "foo" ("x" "y") swank::%cursor-marker%))
      ("(defun foo (x y*HERE*"        ("defun" "foo" ("x" "y" swank::%cursor-marker%)))
      ("(apply 'foo*HERE*"            ("apply" "'foo" swank::%cursor-marker%))
      ("(apply #'foo*HERE*"           ("apply" "#'foo" swank::%cursor-marker%))
      ("(declare ((vector bit *HERE*" ("declare" (("vector" "bit" "" swank::%cursor-marker%))))
      ("(with-open-file (*HERE*"      ("with-open-file" ("" swank::%cursor-marker%)))
      ("(((*HERE*"                    ((("" swank::%cursor-marker%))))
      ("(defun #| foo #| *HERE*"      ("defun" "" swank::%cursor-marker%))
      ("(defun #-(and) (bar) f*HERE*" ("defun" "f" swank::%cursor-marker%)))
  (slime-check-top-level)
  (with-temp-buffer
    (lisp-mode)
    (insert buffer-sexpr)
    (search-backward "*HERE*")
    (delete-region (match-beginning 0) (match-end 0))
    (slime-check-buffer-form result-form)
    (insert ")") (backward-char)
    (slime-check-buffer-form result-form)      
    ))

(provide 'slime-parse)

(let ((byte-compile-warnings '()))
  (mapc #'byte-compile
        '(slime-make-form-spec-from-string
          slime-parse-form-upto-point
          slime-compare-char-syntax
          )))