;; package.lisp - Package Defs for Randhound
;;
;; DM/Emotiq  03/18
;; ---------------------------------------------------------------
#|
The MIT License

Copyright (c) 2018 Emotiq AG

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
|#

(defpackage :randhound/common
  (:use :common-lisp
   :core-crypto
   :pbc
   :vec-repr)
  (:import-from :cosi-keying
   :need-integer-form
   :published-form
   :make-random-keypair
   :validate-pkey)
  (:export
   :*max-bft*
   :node-assoc
   :node-assoc-pkey
   :node-assoc-ip
   :node-assoc-port
   :init-nodes
   :add-node
   :remove-node
   :find-node
   :get-nodes-vector
   :need-integer-form
   :published-form
   :record-to-log
   :broadcast-message
   :send-message
   :get-timestamp
   :NYI
   :session-config
   :session-config-pkeys
   :session-config-tgrps
   :session-config-max-bft
   :session-config-purpose
   :session-config-tstamp

   :subgroup-commit
   :subgroup-commit-thresh
   :subgroup-commit-encr-shares
   :subgroup-commit-proofs
   :make-subgroup-commit
   ))

(defpackage :randhound/client
  (:use :common-lisp
        :core-crypto
        :randhound/common
        :pbc
        :vec-repr)
  (:export
   ))

(defpackage :randhound/server
  (:use :common-lisp
        :core-crypto
        :randhound/common
        :vec-repr
        :pbc
        :actors)
  (:export
   ))

