(in-package :cl-rabbit)

(defun convert-to-bytes (array)
  (labels ((mk-byte8 (a)
             (let ((result (make-array (length a) :element-type '(unsigned-byte 8))))
               (map-into result #'(lambda (v)
                                    (unless (typep v '(unsigned-byte 8))
                                      (error "Value ~s in input array is not an (UNSIGNED-BYTE 8)" v))
                                    v)
                         array)
               result)))
    (typecase array
      ((simple-array (unsigned-byte 8) (*)) array)
      (t (mk-byte8 array)))))

(defun array-to-foreign-char-array (array)
  (let ((result (convert-to-bytes array)))
    ;; Due to a bug in ABCL, CFFI:CONVERT-TO-FOREIGN cannot be used.
    ;; Until this bug is fixed, let's just use a workaround.
    #-abcl (cffi:convert-to-foreign result (list :array :unsigned-char (length result)))
    #+abcl (let* ((length (length result))
                  (type (list :array :unsigned-char length))
                  (foreign-array (cffi:foreign-alloc type :count length)))
             (loop
               for v across result
               for i from 0
               do (setf (cffi:mem-aref foreign-array :unsigned-char i) v))
             foreign-array)))

(defmacro with-foreign-buffer-from-byte-array ((sym buffer) &body body)
  (let ((s (gensym "FOREIGN-BUFFER-")))
    `(let ((,s (array-to-foreign-char-array ,buffer)))
       (unwind-protect
            (let ((,sym ,s))
              (progn ,@body))
         (cffi:foreign-free ,s)))))

(defmacro with-bytes-struct ((symbol value) &body body)
  (let ((value-sym (gensym "VALUE-"))
        (buf-sym (gensym "BUF-")))
    `(let ((,value-sym ,value))
       (with-foreign-buffer-from-byte-array (,buf-sym ,value-sym)
         (let ((,symbol (list 'len (array-dimension ,value-sym 0)
                              'bytes ,buf-sym)))
           ,@body)))))

(defun bytes->array (bytes)
  (let ((pointer (getf bytes 'bytes))
        (length (getf bytes 'len)))
    (unless (and pointer length)
      (error "Argument does not contain the bytes and len fields"))
    (convert-to-bytes (cffi:convert-from-foreign pointer (list :array :unsigned-char length)))))

(defun bytes->string (bytes)
  (babel:octets-to-string (bytes->array bytes) :encoding :utf-8))

(defmacro with-bytes-string ((symbol string) &body body)
  (alexandria:with-gensyms (fn value a string-sym)
    `(let ((,string-sym ,string))
       (labels ((,fn (,a) (let ((,symbol ,a)) ,@body)))
         (if (and ,string-sym (plusp (length ,string-sym)))
             (with-bytes-struct (,value (babel:string-to-octets ,string-sym :encoding :utf-8))
               (,fn ,value))
             (,fn amqp-empty-bytes))))))

(defmacro with-bytes-strings ((&rest definitions) &body body)
  (if definitions
      `(with-bytes-string ,(car definitions)
         (with-bytes-strings ,(cdr definitions)
           ,@body))
      `(progn ,@body)))

(defun call-with-timeval (fn time)
  (if time
      (cffi:with-foreign-objects ((native-timeout '(:struct timeval)))
        (multiple-value-bind (secs microsecs) (truncate time 1000000)
          (setf (cffi:foreign-slot-value native-timeout '(:struct timeval) 'tv-sec) secs)
          (setf (cffi:foreign-slot-value native-timeout '(:struct timeval) 'tv-usec) microsecs)
          (funcall fn native-timeout)))
      (funcall fn (cffi-sys:null-pointer))))

(defmacro with-foreign-timeval ((symbol time) &body body)
  (alexandria:with-gensyms (arg-sym)
    `(call-with-timeval #'(lambda (,arg-sym) (let ((,symbol ,arg-sym)) ,@body)) ,time)))

(declaim (inline bzero-ptr))
(defun bzero-ptr (ptr size)
  (declare (optimize (speed 3) (safety 1))
           (type cffi:foreign-pointer ptr)
           (type fixnum size))
  (loop
    for i from 0 below size
    do (setf (cffi:mem-aref ptr :char i) 0))
  (values))

(defparameter *field-kind-types*
  '((:amqp-field-kind-boolean . value-boolean)
    (:amqp-field-kind-i8 . value-i8)
    (:amqp-field-kind-i8 . value-i8)
    (:amqp-field-kind-u8 . value-u8)
    (:amqp-field-kind-i16 . value-i16)
    (:amqp-field-kind-u16 . value-u16)
    (:amqp-field-kind-i32 . value-i32)
    (:amqp-field-kind-u32 . value-u32)
    (:amqp-field-kind-i64 . value-i64)
    (:amqp-field-kind-u64 . value-u64)
    (:amqp-field-kind-f32 . value-f32)
    (:amqp-field-kind-f64 . value-f64)
    (:amqp-field-kind-decimal . value-decimal)
    (:amqp-field-kind-utf8 . value-bytes)
    (:amqp-field-kind-array . value-array)
    (:amqp-field-kind-timestamp . value-timestamp)
    (:amqp-field-kind-table . value-table)
    (:amqp-field-kind-void . value-void)
    (:amqp-field-kind-bytes . value-bytes)))

(defun create-amqp-table (values)
  (let ((length (length values))
        (allocated-values nil))

    (labels ((string-native (string)
               (let* ((utf (babel:string-to-octets string :encoding :utf-8))
                      (ptr (array-to-foreign-char-array utf)))
                 (push ptr allocated-values)
                 (list 'len (array-dimension utf 0) 'bytes ptr)))

             (typed-value (type value)
               (let ((struct-entry-name (cdr (assoc type *field-kind-types*))))
                 (unless struct-entry-name
                   (error "Illegal kind: ~s" type))
                 (list 'kind (cffi:foreign-enum-value 'amqp-field-value-kind-t type) struct-entry-name value)))

             (make-field-value (value)
               (etypecase value
                 (string (typed-value :amqp-field-kind-utf8 (string-native value)))
                 ((integer #.(- (expt 2 31)) #.(1- (expt 2 31))) (typed-value :amqp-field-kind-i32 value))
                 (boolean (typed-value :amqp-field-kind-boolean (if t 1 0)))
                 (list (multiple-value-bind (table-struct allocated-values%)
                           (create-amqp-table value)
                         (setf allocated-values (append allocated-values allocated-values%))
                         (typed-value :amqp-field-kind-table table-struct))))))

      (let ((content (car (setf allocated-values (list (cffi:foreign-alloc '(:struct amqp-table-entry-t) :count length))))))
        (loop
          for (key . value) in values
          for i from 0
          do (setf (cffi:mem-aref content '(:struct amqp-table-entry-t) i)
                   (list 'key (string-native key) 'value (make-field-value value))))
        (let ((content-struct (list 'num-entries length 'entries content)))
          (values content-struct allocated-values))))))

(defun call-with-amqp-table (fn values)
  (multiple-value-bind (content-struct allocated-values)
      (create-amqp-table values)
    (unwind-protect
         (funcall fn content-struct)
         ;; Unwind form
         (dolist (ptr allocated-values)
           (cffi:foreign-free ptr)))))

(defmacro with-amqp-table ((table values) &body body)
  (alexandria:with-gensyms (values-sym fn)
    `(let ((,values-sym ,values))
       (labels ((,fn (,table) ,@body))
         (if ,values-sym
             (call-with-amqp-table #',fn ,values-sym)
             (,fn amqp-empty-table))))))

(defun amqp-array->lisp (amqp-array)
  (let ((array (vector)))
    (loop for i from 0 below (getf amqp-array 'num-entries)
          do (setf (aref array i)
                   (amqp-field-value->lisp (cffi:mem-aref (getf amqp-array 'entries) '(:struct amqp-field-value-t) i))))))

(defun amqp-decimal->lisp (amqp-decimal)
  (/ (getf amqp-decimal 'value) (expt 10 (getf amqp-decimal 'decimals))))

(defun amqp-field-value->lisp (amqp-field-value)
  (let ((kind (cffi:foreign-enum-keyword 'amqp-field-value-kind-t (getf amqp-field-value 'kind))))
    (ecase kind
      (:amqp-field-kind-boolean (getf amqp-field-value 'value-boolean))
      (:amqp-field-kind-i8 (getf amqp-field-value 'value-i8))
      (:amqp-field-kind-u8 (getf amqp-field-value 'value-u8))
      (:amqp-field-kind-i16 (getf amqp-field-value 'value-i16))
      (:amqp-field-kind-u16 (getf amqp-field-value 'value-u16))
      (:amqp-field-kind-i32 (getf amqp-field-value 'value-i32))
      (:amqp-field-kind-u32 (getf amqp-field-value 'value-u32))
      (:amqp-field-kind-i64 (getf amqp-field-value 'value-i64))
      (:amqp-field-kind-u64 (getf amqp-field-value 'value-u64))
      (:amqp-field-kind-f32 (getf amqp-field-value 'value-f32))
      (:amqp-field-kind-f64 (getf amqp-field-value 'value-f64))
      (:amqp-field-kind-utf8 (bytes->string (getf amqp-field-value 'value-bytes)))
      (:amqp-field-kind-bytes (bytes->array (getf amqp-field-value 'value-bytes)))
      (:amqp-field-kind-table (amqp-table->lisp (getf amqp-field-value 'value-table)))
      (:amqp-field-kind-array (amqp-array->lisp (getf amqp-field-value 'value-array)))
      (:amqp-field-kind-decimal (amqp-decimal->lisp (getf amqp-field-value 'value-array))))))

(defun amqp-table-entry->lisp (table-entry)
  (let ((key (bytes->string (getf table-entry 'key))))
    (cons key
          (amqp-field-value->lisp
           (getf table-entry 'value)))))

(defun amqp-table->lisp (table)
  (loop for i from 0 below (getf table 'num-entries)
        collect (amqp-table-entry->lisp (cffi:mem-aref (getf table 'entries) '(:struct amqp-table-entry-t) i))))

(defmacro print-unreadable-safely ((&rest slots) object stream &body body)
  "A version of PRINT-UNREADABLE-OBJECT and WITH-SLOTS that is safe to use with unbound slots"
  (let ((object-copy (gensym "OBJECT"))
        (stream-copy (gensym "STREAM")))
    `(let ((,object-copy ,object)
           (,stream-copy ,stream))
       (symbol-macrolet ,(mapcar #'(lambda (slot-name)
                                     `(,slot-name (if (and (slot-exists-p ,object-copy ',slot-name)
                                                           (slot-boundp ,object-copy ',slot-name))
                                                      (slot-value ,object-copy ',slot-name)
                                                      :not-bound)))
                          slots)
         (print-unreadable-object (,object-copy ,stream-copy :type t :identity nil)
           ,@body)))))
