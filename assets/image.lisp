#|
 This file is a part of trial
 (c) 2017 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial)

(defclass image (gl-asset texture)
  ())

(defgeneric load-image (path type &key width height depth pixel-type format &allow-other-keys))

(defmethod load-image (path (type (eql :tga)) &key)
  (let* ((tga (tga:read-tga path))
         (buffer (make-static-vector (length (tga:image-data tga))
                                     :initial-contents (tga:image-data tga))))
    (with-cleanup-on-failure (maybe-free-static-vector buffer)
      (values buffer
              (tga:image-width tga)
              (tga:image-height tga)
              (/ (tga:image-bpp tga)
                 (tga:image-channels tga))
              :unsigned
              (ecase (tga:image-channels tga)
                (3 :bgr)
                (4 :bgra))))))

(defmethod load-image (path (type (eql :png)) &key)
  (let ((png (pngload:load-file path :flatten T :flip-y T :static-vector T)))
    (mark-static-vector (pngload:data png))
    (with-cleanup-on-failure (maybe-free-static-vector (pngload:data png))
      (values (pngload:data png)
              (pngload:width png)
              (pngload:height png)
              (pngload:bit-depth png)
              :unsigned
              (ecase (pngload:color-type png)
                (:greyscale :red)
                (:greyscale-alpha :rg)
                (:truecolour :rgb)
                (:truecolour-alpha :rgba)
                (:indexed-colour
                 (error "FIXME: Can't deal with indexed colour.")))))))

(defmethod load-image (path (type (eql :tiff)) &key)
  (let* ((tiff (retrospectiff:read-tiff-file path))
         (bits (aref (retrospectiff:tiff-image-bits-per-sample tiff) 1))
         (buffer (make-static-vector (length (retrospectiff:tiff-image-data tiff))
                                     :initial-contents (retrospectiff:tiff-image-data tiff))))
    ;; FIXME: higher bittage than 8 still returns an ub8 array, but GL doesn't like it.
    (with-cleanup-on-failure (maybe-free-static-vector buffer)
      (values buffer
              (retrospectiff:tiff-image-width tiff)
              (retrospectiff:tiff-image-length tiff)
              bits
              :unsigned
              (ecase (retrospectiff:tiff-image-samples-per-pixel tiff)
                (1 :red)
                (3 :rgb)
                (4 :rgba))))))

(defmethod load-image (path (type (eql :tif)) &rest args)
  (apply #'load-image path :tiff args))

(defmethod load-image (path (type (eql :jpeg)) &key)
  (multiple-value-bind (height width components) (jpeg:jpeg-file-dimensions path)
    (let ((buffer (make-static-vector (* height width components) :element-type '(unsigned-byte 8))))
      (with-cleanup-on-failure (maybe-free-static-vector buffer)
        (let ((buf (jpeg:decode-image path)))
          (dotimes (i height)
            (dotimes (j width)
              (dotimes (k components)
                (setf (aref buffer (+ (* i width) (* j components) k))
                      (aref buf (+ (* i height) (* j components) k)))))))
        (values buffer
                width
                height
                8
                :unsigned
                (ecase components
                  (1 :red)
                  (2 :rg)
                  (3 :bgr)
                  (4 :bgra)))))))

(defmethod load-image (path (type (eql :jpg)) &rest args)
  (apply #'load-image path :jpeg args))

(defmethod load-image (path (type (eql :raw)) &key width height depth pixel-type format)
  (let ((depth (or depth 8)))
    (with-open-file (stream path :element-type (ecase pixel-type
                                                 ((NIL :unsigned) `(unsigned-byte ,depth))
                                                 (:signed `(signed-byte ,depth))
                                                 (:float (ecase depth
                                                           (16 'short-float)
                                                           (32 'single-float)
                                                           (64 'double-float)))))
      (let* ((data (make-static-vector (file-length stream) :element-type (stream-element-type stream)))
             (c (format-components format))
             (width (or width (when height (/ (length data) height c)) (floor (sqrt (/ (length data) c)))))
             (height (or height (when width (/ (length data) width c)) (floor (sqrt (/ (length data) c))))))
        (loop for reached = 0 then (read-sequence data stream :start reached)
              while (< reached (length data)))
        (values data
                width
                height
                depth
                pixel-type
                format)))))

(defmethod load-image (path (type (eql :r16)) &rest args)
  (apply #'load-image path :raw :depth 16 :pixel-type :float args))

(defmethod load-image (path (type (eql :r32)) &rest args)
  (apply #'load-image path :raw :depth 32 :pixel-type :float args))

(defmethod load-image (path (type (eql :ter)) &key)
  (let ((terrain (terrable:read-terrain path)))
    (tg:cancel-finalization terrain)
    (values (terrable:data terrain)
            (terrable:width terrain)
            (terrable:height terrain)
            16
            :signed
            :red)))

(defmethod load-image (path (type (eql T)) &rest args)
  (let ((type (pathname-type path)))
    (apply #'load-image path (intern (string-upcase type) "KEYWORD") args)))

(defun free-image-data (data)
  (etypecase data
    (cffi:foreign-pointer
     (cffi:foreign-free data))
    (vector
     (maybe-free-static-vector data))))

(defmethod load ((image image))
  (flet ((load-image (path)
           (with-new-value-restart (path) (new-path "Specify a new image path.")
             (with-retry-restart (retry "Retry loading the image path.")
               (load-image path T)))))
    (let ((input (coerce-asset-input image T)))
      (multiple-value-bind (bits width height depth type pixel-format) (load-image (unlist input))
        (assert (not (null bits)))
        (with-unwind-protection (mapcar #'free-image-data (enlist (pixel-data image)))
          ;; FIXME: Maybe attempt to reconcile/compare user-provided data?
          (setf (pixel-data image) bits)
          (when width
            (setf (width image) width))
          (when height
            (setf (height image) height))
          (when pixel-format
            (setf (pixel-format image) pixel-format))
          (when (and depth type)
            (setf (pixel-type image) (infer-pixel-type depth type)))
          (when (and depth type pixel-format)
            (setf (internal-format image) (infer-internal-format depth type pixel-format)))
          (when (listp input)
            (setf (pixel-data image) (list (pixel-data image)))
            (dolist (input (rest input))
              (multiple-value-bind (bits width height depth type pixel-format) (load-image input)
                (when width
                  (assert (= width (width image))))
                (when height
                  (assert (= height (height image))))
                (when pixel-format
                  (assert (eq pixel-format (pixel-format image))))
                (when (and depth type)
                  (assert (eq (infer-pixel-type depth type) (pixel-type image))))
                (when (and depth type pixel-format)
                  (assert (eq (infer-internal-format depth type pixel-format) (internal-format image))))
                (push bits (pixel-data image))))
            (setf (pixel-data image) (nreverse (pixel-data image))))
          (allocate image))))))

(defmethod resize ((image image) width height)
  (error "Resizing is not implemented for images."))
