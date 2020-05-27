;; A simple betting game using flip-coin with player matching
;;
;; For more details see docs/flip-coin.md

(define-constant default-amount u1000)
(define-constant new-slot {bet-true: none, bet-false: none, amount: default-amount, created-at: u0})
(define-constant err-bet-exists u10)
(define-constant err-flip-failed u11)

;; storage
(define-map gamblers ((height uint)) ((bet-true principal) (bet-false principal)))
(define-map amounts ((height uint)) ((amount uint)))
(define-map matched-bets ((created-at uint)) ((height uint)))

(define-data-var pending-payout (optional uint) none)
(define-data-var next-slot {bet-true: (optional principal), bet-false: (optional principal),
  amount: uint, created-at: uint}
  new-slot)

;; store information about tax office to pay tax on prize immediately
(use-trait tax-office-trait .flip-coin-tax-office.tax-office-trait)

;; returns how much stx were bet at the given block
(define-read-only (get-amount-at (height uint))
  (match (map-get? amounts ((height height)))
    amount (get amount amount)
    u0
  )
)

;; returns the winner at the given block. If there was no winner `(none)` is returned
(define-read-only (get-optional-winner-at (height uint))
  (match (map-get? gamblers ((height height)))
    game-slot  (let ((value (contract-call? .flip-coin flip-coin-at (+ height u1))))
                  (if value
                    (some (get bet-true game-slot))
                    (some (get bet-false game-slot))
                ))
    none
  )
)

;; splits the prize money
;; 10% goes to another account
;; the rest to the winner
(define-private (shared-amounts (amount uint))
   (let ((shared (/ (* amount u10) u100)))
    {winner: (- amount shared),
    shared: shared,}
  )
)
;; pays the bet amount at the given block
;; height must be below the current height
;; 10% goes to the tax office
(define-private (payout (height (optional uint)) (tax-office <tax-office-trait>))
 (match height
  some-height (if (<= block-height some-height)
    true
    (let ((shared-prize (shared-amounts (get-amount-at some-height))))
      (begin
        (unwrap-panic (as-contract (stx-transfer? (get winner shared-prize) tx-sender (unwrap-panic (get-optional-winner-at some-height)))))
        (unwrap-panic (as-contract (contract-call? tax-office pay-tax (get shared shared-prize))))
        (var-set pending-payout none)
      )
    ))
  true
 )
)

(define-private (next-gambler (value bool))
  (if value
        (get bet-true (var-get next-slot))
        (get bet-false (var-get next-slot))
  )
)

(define-data-var trigger (optional uint) none)
(define-private (panic)
  (ok {created-at: (unwrap-panic (var-get trigger)), bet-at: u0})
)

(define-private (update-game-after-payment (value bool) (amount uint))
  (match (next-gambler (not value))
    opponent (if (map-insert gamblers ((height block-height))
                    {
                      bet-true: (if value tx-sender opponent),
                      bet-false: (if value opponent tx-sender)
                    }
                  )
                  (if (map-insert amounts ((height block-height))  ((amount (+ amount amount))))
                    (begin
                      (map-insert matched-bets {created-at: (get created-at (var-get next-slot))} {height: block-height})
                      (var-set next-slot new-slot)
                      (var-set pending-payout (some block-height))
                      (ok {
                            created-at: (get created-at (var-get next-slot)),
                            bet-at: block-height
                          })
                    )
                    (panic)
                  )
                (panic)
              )
    (begin
      (var-set next-slot {
        bet-true: (if value (some tx-sender) none),
        bet-false: (if value none (some tx-sender)),
        created-at: block-height,
        amount: amount
        })
      (ok {created-at: block-height, bet-at: u0})
    )
  )
)

;; bet 1000 mSTX on the given value. Only one user can bet on that value for each block.
;; if payout needs to be done then this function call will do it (note that the caller
;; needs to provide corresponding post conditions)
(define-public (bet (value bool) (tax-office <tax-office-trait>))
  (let ((amount default-amount))
    (begin
      (payout (var-get pending-payout) tax-office)
      (if (is-some (next-gambler value))
        (err err-bet-exists)
        (begin
          (match (stx-transfer? amount tx-sender (as-contract tx-sender))
            success (update-game-after-payment value amount)
            error (err error)
          )
        )
      )
    )
  )
)
