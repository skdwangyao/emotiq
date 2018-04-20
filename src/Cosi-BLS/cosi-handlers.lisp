;; cosi-handlers.lisp -- Handlers for various Cosi operations
;;
;; DM/Emotiq  02/18
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

(in-package :cosi-simgen)
;; ---------------------------------------------------------------

(defun NYI (&rest args)
  (error "Not yet implemented: ~A" args))

;; -------------------------------------------------------

(defun node-dispatcher (node &rest msg)
   (um:dcase msg
     ;; ----------------------------
     ;; user accessible entry points - directed to leader node
     
     (:cosi-sign-prepare (reply-to msg)
      (node-compute-cosi node reply-to :prepare msg))

     (:cosi-sign-commit (reply-to msg)
      (node-compute-cosi node reply-to :commit msg))

     (:cosi-sign (reply-to msg)
      (node-compute-cosi node reply-to :notary msg))
     
     (:new-transaction (reply-to msg)
      (node-check-transaction node reply-to msg))
     
     (:validate (reply-to sig bits)
      (node-validate-cosi reply-to sig bits))
          
     (:public-key (reply-to)
      (reply reply-to :pkey+zkp (node-pkeyzkp node)))

     (:add/change-node (new-node-info)
      (node-insert-node node new-node-info))

     (:remove-node (node-ip)
      (node-remove-node node node-ip))
     
     (:election (new-leader-ip)
      (node-elect-new-leader new-leader-ip))

     ;; -------------------------------
     ;; internal comms between Cosi nodes
     
     (:signing (reply-to consensus-stage msg seq)
      (case consensus-stage
        (:notary 
         (node-cosi-notary-signing node reply-to
                                   consensus-stage msg seq))
        (otherwise
         (node-cosi-signing node reply-to
                            consensus-stage msg seq))
        ))

     ;; -----------------------------------
     ;; for sim and debug
     
     (:answer (&rest msg)
      ;; for round-trip testing
      (ac:pr msg))

     (:reset ()
      (node-reset-nodes node))
     
     (t (&rest msg)
        (error "Unknown message: ~A~%Node: ~A" msg (node-ip node)))
     ))

;; -------------------------------------------------------

(defun make-node-dispatcher (node)
  ;; use indirection to node-dispatcher for while we are debugging and
  ;; extending the dispatcher. Saves reconstructing the tree every
  ;; time the dispatching chanages.
  (ac:make-actor
   ;; one of these closures is stored in the SELF slot of every node
   (lambda (&rest msg)
     (apply 'node-dispatcher node msg))))

(defun crash-recovery ()
  ;; just in case we need to re-make the Actors for the network
  (maphash (lambda (k node)
             (declare (ignore k))
             (setf (node-self node) (make-node-dispatcher node)))
           *ip-node-tbl*))


;; -------------------------------------------------------
;; New leader node election... tree rearrangement

(defun notify-real-descendents (node &rest msg)
  (labels ((recurse (sub-node)
             (if (node-realnode sub-node)
                 (apply 'send sub-node msg)
               (iter-subs sub-node #'recurse))))
    (iter-subs node #'recurse)))

(defun all-nodes-except (node)
  (delete node
          (um:accum acc
            (maphash (um:compose #'acc 'um:snd) *ip-node-tbl*))))

(defun node-model-rebuild-tree (parent node nlist)
  (let ((bins (partition node nlist
                         :key 'node-ip)))
    (iteri-subs node
                (lambda (ix subs)
                  (setf (aref bins ix)
                        (node-model-rebuild-tree node
                                                 (car subs)
                                                 (cdr subs)))))
    (setf (node-parent node) parent)
    (set-node-load node)
    node))

(defun node-elect-new-leader (new-leader-ip)
  (let ((new-top-node (gethash new-leader-ip *ip-node-tbl*)))
    ;; Maybe... ready for prime time?
    (cond ((null new-top-node)
           (error "Not a valid leader node: ~A" new-leader-ip))
          ((eq new-top-node *top-node*)
           ;; nothing to do here...
           )
          (t
           (setf *top-node* new-top-node)
           (node-model-rebuild-tree nil new-top-node
                                    (all-nodes-except new-top-node))
           ;;
           ;; The following broadcast will cause us to get another
           ;; notification, but by then the *top-node* will already
           ;; have been set to new-leader-ip, and so no endless loop
           ;; will occur.
           ;;
           (notify-real-descendents new-top-node :election new-leader-ip))
          )))

;; ---------------------------------------------------------
;; Node insertion/change

(defun bin-for-ip (node ip)
  (let ((vnode  (dotted-string-to-integer (node-ip node)))
        (vip    (dotted-string-to-integer ip)))
    (mod (logxor vnode vip) (length (node-subs node)))))

(defun increase-loading (parent-node)
  (when parent-node
    (incf (node-load parent-node))
    (increase-loading (node-parent parent-node))))

(defun node-model-insert-node (node new-node-info)
  ;; info is (ipv4 pkeyzkp)
  (destructuring-bind (ipstr pkeyzkp) new-node-info
    (let* ((ix       (bin-for-ip node ipstr))
           (bins     (node-subs node))
           (sub-node (aref bins ix)))
      (if sub-node
          ;; continue in parallel with our copy of tree
          (node-model-insert-node sub-node new-node-info)
        ;; else
        (let ((new-node (make-node ipstr pkeyzkp node)))
          (setf (node-real-ip new-node)  ipstr
                (node-skey new-node)     nil
                (aref bins ix)           new-node)
          (incf (node-load node))
          (increase-loading (node-parent node)))
        ))))

(defun node-insert-node (node new-node-info)
  (destructuring-bind (ipstr pkeyzkp) new-node-info
    (let ((new-node (gethash ipstr *ip-node-tbl*)))
      (if new-node ;; already present in tree?
          ;; maybe caller just wants to change keying
          ;; won't be able to sign unless it know skey
          (multiple-value-bind (pkey ok) (check-pkey pkeyzkp)
            (when ok
              (setf (node-pkeyzkp new-node)  pkeyzkp
                    (node-pkey new-node)     pkey ;; cache the decompressed key
                    (node-real-ip new-node)  ipstr)))
        ;; else - not already present
        (node-model-insert-node *top-node* new-node-info))))
  (notify-real-descendents node :insert-node new-node-info))

;; ---------------------------------------------------------

(defun node-model-remove-node (gone-node)
  (remhash (node-ip gone-node) *ip-node-tbl*)
  (let ((pcmpr (keyval (first (node-pkeyzkp gone-node)))))
    (remhash pcmpr *pkey-node-tbl*)
    (remhash pcmpr *pkey-skey-tbl*)))

(defun node-remove-node (node gone-node-ipv4)
  (let ((gone-node (gethash gone-node-ipv4 *ip-node-tbl*)))
    (when gone-node
      (node-model-remove-node gone-node)
      ;; must rebuild tree to absorb node's subnodes
      (node-model-rebuild-tree nil *top-node*
                               (all-nodes-except *top-node*))
      (when (eq node *top-node*)
        (notify-real-descendents node :remove-node gone-node-ipv4)))))
  
#|
(send *top-node* :public-key (make-node-ref *my-node*))
==> see results in output window
(:PKEY+ZKP (849707610687761353988031598913888011454228809522136330182685594047565816483 77424688591828692687552806917061506619936267795838123291694715575735109065947 2463653704506470449709613051914446331689964762794940591210756129064889348739))

COSI-SIMGEN 23 > (send (gethash "10.0.1.6" *ip-node-tbl*) :public-key (make-node-ref *my-node*))

Connecting to #$(NODE "10.0.1.6" 65000)
(FORWARDING "10.0.1.6" (QUOTE ((:PUBLIC-KEY #<NODE-REF 40200014C3>) 601290835549702797100992963662352678603116278028765925372703953633797770499 56627041402452754830116071111198944351637771601751353481660603190062587211624 23801716726735741425848558528841292842)))
==> output window
(:PKEY+ZKP (855676091672863312136583105058123818001884231695959658747310415728976873583 19894104797779289660345137228823739121774277312822467740314566093297448396984 2080524722754689845098528285145820902670538507089109456806581872878115260191))
|#
#|
(defun ptst ()
  ;; test requesting a public key
  (spawn
   (lambda ()
     (let* ((my-ip    (node-real-ip *my-node*))
            (my-port  (start-ephemeral-server))
            (ret      (make-return-addr my-ip my-port)))
         (labels
             ((exit ()
                (become 'do-nothing)
                (unregister-return-addr ret)
                (shutdown-server my-port)))
           (pr :my-port my-port)
           #+:LISPWORKS (inspect ret)
           (send *my-node* :public-key ret)
           (recv
             (msg
              (pr :I-got... msg)
              (exit))
             :TIMEOUT 2
             :ON-TIMEOUT
             (progn
               (pr :I-timed-out...)
               (exit))
             ))))
   ))

(defun stst (msg)
  ;; test getting a signature & verifying it
  (spawn
   (lambda ()
     (let* ((my-ip    (node-real-ip *my-node*))
            (my-port  (start-ephemeral-server))
            (ret      (make-return-addr my-ip my-port)))
       (labels
           ((exit ()
              (become 'do-nothing)
              (unregister-return-addr ret)
              (shutdown-server my-port)))
         (pr :my-port my-port)
         #+:LISPWORKS (inspect ret)
         (send *top-node* :cosi-sign ret msg)
         (recv
           ((list :answer (and packet
                               (list :signature _ sig)))
            (pr :I-got... packet)
            (pr (format nil "Witnesses: ~A" (logcount (um:last1 sig))))
            (send *my-node* :validate ret msg sig)
            (recv
              (ansv
               (pr :Validation ansv)
               (exit))
              :TIMEOUT 1
              :ON-TIMEOUT
              (pr :timed-out-on-signature-verification)
              (exit)))
           
           (xmsg
            (pr :what!? xmsg)
            (exit))
           
           :TIMEOUT 15
           :ON-TIMEOUT
           (progn
             (pr :I-timed-out...)
             (exit))
           ))))
   ))
|#         

;; --------------------------------------------------------------------

(defmethod node-check-transaction (node reply-to msg)
  "Just ignore invalid messages"
  nil)

(defmethod node-check-transaction (node reply-to (msg transaction))
  (check-transaction-math msg))

;; -------------------------------
;; testing-version transaction cache

(defvar *trans-cache*  (make-hash-table
                        :test 'equalp))

(defun cache-transaction (key val)
  (setf (gethash key *trans-cache*) val))

(defun lookup-transaction (key)
  (gethash key *trans-cache*))

;; -------------------------------
;; testing-version TXOUT log

(defvar *utxo-table*  (make-hash-table
                      :test 'equalp))

(defun record-new-utx (key)
  "KEY is Hash(P,C) of TXOUT - record tentative TXOUT. Once finalized,
they will be added to utxo-table"
  (multiple-value-bind (x present-p)
      (gethash key *utxo-table*)
    (declare (ignore x))
    (when present-p
      (error "Shouldn't Happen: Effective Hash Collision!!!"))
    (setf (gethash key *utxo-table*) :spendable)))

;; -------------------------------------------------------------------
;; Code to check incoming transactions for self-validity, not
;; inter-transactional validity like double-spend

(defun txin-keys (tx)
  (mapcar (um:compose 'int 'txin-hashlock) (trans-txins tx)))

(defun txout-keys (tx)
  (mapcar (um:compose 'int 'txout-hashlock) (trans-txouts tx)))

(defun check-transaction-math (tx)
  "TX is a transaction. Check that no TXIN refers to one of the TXOUT.
Check that every TXIN and TXOUT has a valid range proof, and that the
sum of TXIN equals the sum of TXOUT.

If passes these checks, record the transaction and its hash in a pair
in a cache log to speed up later block validation.

Return nil if transaction is invalid."
  (let* ((key        (hash/256 tx))
         (txout-keys (txout-keys tx)))
    (when (and (notany (lambda (txin)
                         ;; can't be spending an output you are just
                         ;; now creating
                         (find txin txout-keys))
                       (txin-keys tx))
               ;; now do the math
               (validate-transaction tx))
      (cache-transaction key (list key tx)))
    ))     

;; --------------------------------------------------------------------
;; Code to assemble a block - must do full validity checking,
;; including double-spend checks

(defun partial-order (t1 t2)
  "Return T if inputs follow outputs"
  (let ((txouts1 (txout-keys t1))
        (txins2  (txin-keys  t2)))
    (some (lambda (txin)
            (member txin txouts1))
          txins2)))

(defstruct txrec
  txpair txkey ins outs)

(defun topo-sort (tlst)
  "Topological partial ordering of transactions. TXOUT generators need
to precede TXIN consumers.

TLST is a list of pairs (k v) with k being the hash of the
transaction, and v being the transaction itself."
  ;; first, compute lists of keys just once
  (let ((txrecs (mapcar (lambda (pair)
                          (destructuring-bind (k tx) pair
                            (make-txrec
                             :txkey  k
                             :txpair pair
                             :ins    (txin-keys tx)
                             :outs   (txout-keys tx))))
                        tlst)))
    (labels ((depends-on (a b)
               ;; return true if a depends on b
               (let ((ins  (txrec-ins a))
                     (outs (txrec-outs b)))
               (some (um:rcurry 'member outs) ins)))
             
             (depends-on-some (a lst)
               ;; true if a depends on some element of lst
               (some (um:curry #'depends-on a) lst)))
      
      (mapcar 'txrec-txpair ;; convert back to incoming pairs
              (um:accum acc
                (um:nlet-tail outer ((lst txrecs))
                  (when lst
                    (let ((rem (um:nlet-tail iter ((lst  lst)
                                                   (rest nil))
                                 (if (endp lst)
                                     rest
                                   (let ((hd (car lst))
                                         (tl (cdr lst)))
                                     (cond ((depends-on hd hd)
                                            ;; if we depend on our own outputs,
                                            ;; then invalid TX
                                            (remhash (txrec-txkey hd) *trans-cache*)
                                            (iter tl rest))
                                           
                                           ((depends-on-some hd (append tl rest))
                                            ;; try next TX
                                            (iter tl (cons hd rest)))
                                           
                                           (t
                                            ;; found a TX with no dependencies on rest of list
                                            (acc hd)
                                            (iter tl rest))
                                           ))
                                   ))))
                      (if (= (length lst) (length rem))
                          ;; no progress made - must be interdependencies
                          (dolist (rec rem)
                            ;; discard TX with circular dependencies and quit
                            (remhash (txrec-txkey rec) *trans-cache*))
                        ;; else -- try for more
                        (outer rem))
                      ))))))))

(defun check-double-spend (tx-pair)
  "TX is transaction in current pending block.  Check every TXIN to be
sure no double-spending, nor referencing unknown TXOUT. Return nil if
invalid TX."
  (destructuring-bind (txkey tx) tx-pair
    (labels ((txin-ok (txin)
               (let ((key (txin-hashlock txin)))
                 ;; if not in UTXO table as :SPENDABLE, then it is invalid
                 (when (eq :spendable (gethash key *utxo-table*))
                   (setf (gethash key *utxo-table*) tx-pair)))))
      (cond ((every #'txin-ok (trans-txins tx))
             (dolist (txout (trans-txouts tx))
               (record-new-utx (txout-hashlock txout)))
             t)
            
            (t
             ;; remove transaction from mempool
             (remhash txkey *trans-cache*)
             (dolist (txin (trans-txins tx))
               (let ((key (txin-hashlock txin)))
                 (when (eq tx-pair (gethash key *utxo-table*)) ;; unspend all
                   (setf (gethash key *utxo-table*) :spendable))
                 ))
             nil)
            ))))

(defun get-candidate-transactions ()
  "Scan available TXs for numerically valid, spend-valid, and return
topo-sorted partial order"
  (let ((txs  nil))
    (maphash (lambda (k v)
               (push (list k v) txs))
             *trans-cache*)
    (let ((trimmed (topo-sort txs)))
      (dolist (tx (set-difference txs trimmed
                                  :key 'car))
        ;; remove invalid transactions whose inputs refer to future
        ;; outupts
        (remhash (car tx) *trans-cache*))
      ;; checking for double spending also creates additional UTXO's.
      (um:accum acc
        (dolist (tx trimmed)
          (when (check-double-spend tx)
            (acc tx))))
      )))
               
(defvar *max-transactions*  16)  ;; max nbr TX per block

(defun get-transactions-for-new-block ()
  (let ((tx-pairs (get-candidate-transactions)))
    (multiple-value-bind (hd tl)
        (um:split *max-transactions* tx-pairs)
      (dolist (tx-pair tl)
        ;; put these back in the pond for next round
        (destructuring-bind (k tx) tx-pair
          (declare (ignore k))
          (dolist (txin (trans-txins tx))
            (let ((key (txin-hashlock txin)))
              (when (eql tx-pair (gethash key *utxo-table*))
                (setf (gethash key *utxo-table*) :spendable))))
          (dolist (txout (trans-txouts tx))
            (remhash (txout-hashlock txout) *utxo-table*))))
      ;; now hd represents the actual transactions going into the next block
      hd)))
      
;; ----------------------------------------------------------------------
;; Code run by Cosi block validators...

(defun #1=check-block-transactions (tlst)
  "TLST is list of transactions from current pending block. Return nil
if invalid block.

List of TX should already have been topologically sorted so that input
UTXO's were created in earlier transactions or earlier blocks in the
blockchain.

Check that there are no forward references in spend position, then
check that each TXIN and TXOUT is mathematically sound."
  (dolist (tx tlst)
    (dolist (txin (trans-txins tx))
      (let ((key  (txin-hashlock txin)))
        (unless (eql :SPENDABLE (gethash key *utxo-table*))
          (return-from #1# nil)) ;; caller must back out the changes made so far...
        (setf (gethash key *utxo-table*) tx))) ;; mark as spend in this TX
    ;; now check for valid transaction math
    (unless (check-transaction-math tx)
      (return-from #1# nil))
    ;; add TXOUTS to UTX table
    (dolist (txout (trans-txouts tx))
      (setf (gethash (txout-hashlock txout) *utxo-table*) :SPENDABLE)))
  t) ;; tell caller everything ok

;; --------------------------------------------------------------------
;; Message handlers for verifier nodes

(defun node-validate-cosi (reply-to sig bits)
  ;; toplevel entry for Cosi signature validation checking
  ;; first check for valid signature...
  (if (pbc:check-message sig)
      ;; we passed signature validation on composite signature
      ;; now verify the public keys making up that signature
      (let* ((pkeys (reduce (lambda (lst node)
                              ;; collect keys from bitmap indication
                              (if (and node
                                       (logbitp (node-bit node) bits))
                                  (cons (node-pkey node) lst)
                                lst))
                            *node-bit-tbl*
                            :initial-value nil))
             ;; compute composite public key
             (tkey  (reduce 'pbc:mul-pts pkeys)))
        (reply reply-to :validation
               ;; see that our computed composite key matches the
               ;; key used in the signature
               (= (vec-repr:int (pbc:signed-message-pkey sig))
                  (vec-repr:int tkey))))
    
    ;; else - we failed initial signature validation
    (reply reply-to :validation nil)))

;; -----------------------------------------------------------------------

#-(AND :COM.RAL :LISPWORKS)
(defparameter *dly-instr*
  (ac:make-actor
   (lambda (&rest args)
     (declare (ignore args))
     t)))

#+(AND :COM.RAL :LISPWORKS)
(defparameter *dly-instr*
  ;; Very useful for timeout tuning. If timeouts are properly set,
  ;; then histogram will be entirely to left of red 1.0 Ratio, but not
  ;; too far left
  (ac:make-actor
   (let ((data   nil)
         (pltsym :plt))
     (um:dlambda
       (:incr (dly)
        (push dly data))
       (:clr ()
        (setf data nil))
       (:pltwin (sym)
        (setf pltsym sym))
       (:plt ()
        (plt:histogram pltsym data
                       :clear  t
                       :ylog   t
                       :xrange '(0 1.2)
                       :thick  2
                       ;; :cum    t
                       :norm   nil
                       :title  "Measured Delay Ratios"
                       :xtitle "Delay-Ratio"
                       :ytitle "Counts")
        (plt:plot pltsym '(1 1) '(0.1 1e6)
                  :color :red))
       ))))

;; -----------------------------------------------------------------------

(defun msg-ok (msg node)
  (declare (ignore msg))
  (not (node-byz node))) ;; for now... should look at node-byz to see how to mess it up

(defun mark-node-no-response (node sub)
  (declare (ignore node sub)) ;; for now...
  nil)

(defun mark-node-corrupted (node sub)
  (declare (ignore node)) ;; for now...
  (setf (node-bad sub) t)
  nil)

;; -----------------------

(defun clear-bad ()
  (send-real-nodes :reset))

(defun node-reset-nodes (node)
  (declare (ignore node))
  (loop for node across *node-bit-tbl* do
        (setf (node-bad node) nil)))

;; ---------------

(defun send-subs (node &rest msg)
  (iter-subs node (lambda (sub)
                    (apply 'send sub msg))))

(defun group-subs (node)
  (um:accum acc
    (iter-subs node #'acc)))

(defun send-real-nodes (&rest msg)
  (loop for ip in *real-nodes* do
        (apply 'send (gethash ip *ip-node-tbl*) msg)))

;; ------------------------------

(defun sub-signing (my-ip consensus-stage msg seq-id)
  (=lambda (node)
    (let ((start    (get-universal-time))
          (timeout  10
                    ;; (* (node-load node) *default-timeout-period*)
                    )
          (ret-addr (make-return-addr my-ip)))
      (send node :signing ret-addr consensus-stage msg seq-id)
      (labels
          ((!dly ()
                 #+:LISPWORKS
                 (send *dly-instr* :incr
                       (/ (- (get-universal-time) start)
                          timeout)))

               (=return (val)
                 (!dly)
                 (unregister-return-addr ret-addr)
                 (=values val))
               
               (wait ()
                 (recv
                   ((list* :signed sub-seq ans)
                    (if (eql sub-seq seq-id)
                        (=return ans)
                      ;; else
                      (wait)))
                   
                   (_
                    (wait))
                   
                   :TIMEOUT timeout
                   :ON-TIMEOUT
                   (progn
                     (pr (format nil "SubSigning timeout waiting for ~A" (node-ip node)))
                     (=return nil))
                   )))
        (wait))
      )))

;; -------------------------------------------------------
;; VALIDATE-COSI-MESSAGE -- this is the one you need to define for
;; each different type of Cosi network... For now, just act as notary
;; service - sign anything.

(defun notary-validate-cosi-message (node consensus-stage msg)
  (declare (ignore node consensus-stage msg))
  t)

;; ------------------------------------------------------------------------

(defvar *byz-thresh*  0)  ;; established at bootstrap time - consensus threshold
(defvar *blockchain*  (make-hash-table
                       :test 'equalp))
(defvar *block*  nil)  ;; next block being assembled

(defun signed-message (msg)
  (NYI "signed-message"))

(defun signed-bitmap (msg)
  (NYI "signed-bitmap"))

(defun compute-block-hash (blk)
  (NYI "compute-block-hash"))

(defun get-block-transactions (blk)
  (NYI "get-block-transactions"))

(defun validate-cosi-message (node consensus-stage msg)
  (declare (ignore node)) ;; for now, in sim as notary
  (ecase consensus-stage
    (:prepare
     ;; msg is a pending block
     ;; returns nil if invalid - should not sign
     (let ((txs  (get-block-transactions msg)))
       (or (check-block-transactions txs)
           ;; back out changes to *utxo-table*
           (dolist (tx txs)
             (dolist (txin (trans-txins tx))
               (let ((key (txin-hashlock txin)))
                 (when (eql tx (gethash key *utxo-table*))
                   (setf (gethash key *utxo-table*) :SPENDABLE))))
             (dolist (txout (trans-txouts tx))
               (remhash (txout-hashlock txout) *utxo-table*))
             nil))))

    (:commit
     ;; message is a block with multisignature check signature for
     ;; validity and then sign to indicate we have seen and committed
     ;; block to blockchain. Return non-nil to indicate willingness to sign.
     (when (and (pbc:check-message (signed-message msg))
                (>= (logcount (signed-bitmap msg)) *byz-thresh*))
       (let* ((blk (pbc:signed-message-msg msg))
              (key (compute-block-hash blk)))
         (setf (gethash key *blockchain*) msg))
       ;; clear out *trans-cache* and spent utxos
       (dolist (tx (get-block-transactions blk))
         (let ((key (hash/256 tx)))
           (remhash key *trans-cache*))
         (dolist (txin (trans-txins tx))
           (remhash (txin-hashlock txin) *utxo-table*)))
       t ;; return true to validate
       ))
    ))

(defun node-cosi-signing (node reply-to consensus-stage msg seq-id)
  ;; Compute a collective BLS signature on the message. This process
  ;; is tree-recursivde.
  (let* ((subs (remove-if 'node-bad (group-subs node))))
    (=bind (ans)
        (par
          (=values 
           ;; Here is where we decide whether to lend our signature. But
           ;; even if we don't, we stil give others in the group a chance
           ;; to decide for themselves
           (if (or (eql node *top-node*)
                   (validate-cosi-message node consensus-stage msg))
               (list (pbc:sign-message msg (node-pkey node) (node-skey node))
                     (node-bitmap node))
             (list nil 0)))
          ;; ... and here is where we have all the subnodes in our
          ;; group do the same, recursively down the Cosi tree.
          (pmapcar (sub-signing (node-real-ip node)
                                consensus-stage
                                msg
                                seq-id)
                   subs))
      (destructuring-bind ((sig bits) r-lst) ans
        (labels ((fold-answer (sub resp)
                   (cond
                    ((null resp)
                     ;; no response from node, or bad subtree
                     (pr (format nil "No signing: ~A" (node-ip sub)))
                     (mark-node-no-response node sub))
                    
                    (t
                     (destructuring-bind (sub-sig sub-bits) resp
                       (if (pbc:check-message sub-sig)
                           (setf sig  (if sig
                                          (pbc:combine-signatures sig sub-sig)
                                        sub-sig)
                                 bits (logior bits sub-bits))
                         ;; else
                         (mark-node-corrupted node sub))
                       ))
                    )))
          (mapc #'fold-answer subs r-lst) ;; gather results from subs
          (send reply-to :signed seq-id sig bits))
        ))))

(defun node-cosi-notary-signing (node reply-to consensus-stage msg seq-id)
  "This code is for simple testing. It will disappear shortly. Don't
bother factoring it with NODE-COSI-SIGNING."
  ;; Compute a collective BLS signature on the message. This process
  ;; is tree-recursivde.
  (let* ((subs (remove-if 'node-bad (group-subs node))))
    (=bind (ans)
        (par
          (=values 
           ;; Here is where we decide whether to lend our signature. But
           ;; even if we don't, we stil give others in the group a chance
           ;; to decide for themselves
           (if (notary-validate-cosi-message node consensus-stage msg)
               (list (pbc:sign-message msg (node-pkey node) (node-skey node))
                     (node-bitmap node))
             (list nil 0)))
          (pmapcar (sub-signing (node-real-ip node)
                                consensus-stage
                                msg
                                seq-id)
                   subs))
      (destructuring-bind ((sig bits) r-lst) ans
        (labels ((fold-answer (sub resp)
                   (cond
                    ((null resp)
                     ;; no response from node, or bad subtree
                     (pr (format nil "No signing: ~A" (node-ip sub)))
                     (mark-node-no-response node sub))
                    
                    (t
                     (destructuring-bind (sub-sig sub-bits) resp
                       (if (pbc:check-message sub-sig)
                           (setf sig  (if sig
                                          (pbc:combine-signatures sig sub-sig)
                                        sub-sig)
                                 bits (logior bits sub-bits))
                         ;; else
                         (mark-node-corrupted node sub))
                       ))
                    )))
          (mapc #'fold-answer subs r-lst) ;; gather results from subs
          (send reply-to :signed seq-id sig bits))
        ))))

;; -----------------------------------------------------------

(defun node-compute-cosi (node reply-to consensus-stage msg)
  ;; top-level entry for Cosi signature creation
  ;; assume for now that leader cannot be corrupted...
  (declare (ignore node))
  (let ((sess (gen-uuid-int)) ;; strictly increasing sequence of integers
        (self (current-actor)))
    (ac:self-call :signing self consensus-stage msg sess)
    (labels
        ((unknown-message (msg)
           (error "Unknown message: ~A" msg))
         
         (wait-signing ()
           (recv
             ((list :signed seq sig bits)
              (cond
               ((eql seq sess)
                (if (pbc:check-message sig)
                    ;; we completed successfully
                    (reply reply-to
                           (list :signature sig bits))
                  ;; bad signature
                  (reply reply-to :corrupt-cosi-network)
                  ))
               ;; ------------------------------------
               (t ;; seq mismatch
                  ;; must have been a late arrival
                  (wait-signing))
               )) ;; end of message pattern
             ;; ---------------------------------
             (msg ;; other messages during commitment phase
                  (unknown-message msg))
             )))
      (wait-signing)
      )))

#|
;; FOR TESTING!!!

(setup-server)

(set-executive-pool 1)

(setf *real-nodes* (list *leader-node*))

(setf *real-nodes* (remove "10.0.1.13" *real-nodes*
                           :test 'string-equal))

(generate-tree :nodes 100)

(reconstruct-tree)
|#

(defun tst ()
  (spawn
   (lambda ()
     (send *dly-instr* :clr)
     (send *dly-instr* :pltwin :histo-4)
     (let ((ret   (make-return-addr (node-real-ip *my-node*)))
           (start (get-universal-time)))
       (labels
           ((exit ()
              (unregister-return-addr ret)))
         (send *top-node* :cosi-sign ret "This is a test message!")
         (recv
           ((list :answer
                  (and msg
                       (list :signature sig bits)))
            (send *dly-instr* :plt)
            (ac:pr
             (format nil "Total Witnesses: ~D" (logcount bits))
             msg
             (format nil "Duration = ~A" (- (get-universal-time) start)))
            
            (send *my-node* :validate ret sig bits)
            (recv
              ((list :answer :validation t/f)
               (if t/f
                   (ac:pr :valid-signature)
                 (ac:pr :invalid-signature))
               (exit))
              
              (msg
               (error "ValHuh?: ~A" msg)
               (exit))
              ))
           
           (msg
            (error "Huh? ~A" msg)
            (exit))
           ))))))

;; -------------------------------------------------------------

(defvar *arroyo*     "10.0.1.2")
(defvar *dachshund*  "10.0.1.3")
(defvar *malachite*  "10.0.1.6")
(defvar *rambo*      "10.0.1.13")

(defmethod damage ((ip string) t/f)
  (damage (gethash ip *ip-node-tbl*) t/f))

(defmethod damage ((node node) t/f)
  (setf (node-byz node) t/f))

(defun init-sim ()
  (shutdown-server)
  (reconstruct-tree)
  (start-server))
