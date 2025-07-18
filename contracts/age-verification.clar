;; Age Verification Contract
;; Validates minor status and provides age-based access controls

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-NOT-FOUND (err u201))
(define-constant ERR-INVALID-AGE (err u202))
(define-constant ERR-VERIFICATION-FAILED (err u203))
(define-constant ERR-ALREADY-VERIFIED (err u204))

;; Age thresholds
(define-constant AGE-THRESHOLD-13 u13)
(define-constant AGE-THRESHOLD-16 u16)
(define-constant AGE-THRESHOLD-18 u18)

;; Data Variables
(define-data-var verification-authority principal tx-sender)

;; Data Maps
(define-map age-verifications
  { subject: principal }
  {
    birth-date: uint,
    verified-age: uint,
    verification-date: uint,
    verification-method: (string-ascii 50),
    verifier: principal,
    confidence-level: uint,
    expires: uint
  }
)

(define-map age-permissions
  { subject: principal, age-gate: uint }
  {
    permitted: bool,
    verification-required: bool,
    last-checked: uint,
    notes: (string-ascii 100)
  }
)

(define-map content-ratings
  { content-id: (string-ascii 100) }
  {
    minimum-age: uint,
    rating-system: (string-ascii 20),
    content-type: (string-ascii 50),
    risk-level: uint
  }
)

;; Read-only functions
(define-read-only (get-age-verification (subject principal))
  (map-get? age-verifications { subject: subject })
)

(define-read-only (calculate-current-age (birth-date uint))
  (let ((current-date (+ u20240101 (/ block-height u144)))) ;; Approximate current date
    (- (/ current-date u10000) (/ birth-date u10000))
  )
)

(define-read-only (is-age-verified (subject principal))
  (match (get-age-verification subject)
    verification (< block-height (get expires verification))
    false
  )
)

(define-read-only (check-age-permission (subject principal) (required-age uint))
  (match (get-age-verification subject)
    verification (>= (get verified-age verification) required-age)
    false
  )
)

(define-read-only (get-content-rating (content-id (string-ascii 100)))
  (map-get? content-ratings { content-id: content-id })
)

(define-read-only (can-access-content (subject principal) (content-id (string-ascii 100)))
  (match (get-content-rating content-id)
    rating (check-age-permission subject (get minimum-age rating))
    true ;; No rating means no restriction
  )
)

(define-read-only (is-minor (subject principal))
  (match (get-age-verification subject)
    verification (< (get verified-age verification) AGE-THRESHOLD-18)
    true ;; Default to minor if not verified
  )
)

;; Private functions
(define-private (is-valid-verification-method (method (string-ascii 50)))
  (or
    (is-eq method "birth-certificate")
    (is-eq method "government-id")
    (is-eq method "parental-attestation")
    (is-eq method "school-record")
  )
)

(define-private (calculate-confidence-level (method (string-ascii 50)))
  (if (is-eq method "government-id")
    u5
    (if (is-eq method "birth-certificate")
      u4
      (if (is-eq method "school-record")
        u3
        u2
      )
    )
  )
)

;; Public functions
(define-public (submit-age-verification (subject principal) (birth-date uint) (method (string-ascii 50)))
  (let (
    (verifier tx-sender)
    (calculated-age (calculate-current-age birth-date))
    (confidence (calculate-confidence-level method))
  )
    (asserts! (is-valid-verification-method method) ERR-VERIFICATION-FAILED)
    (asserts! (> calculated-age u0) ERR-INVALID-AGE)
    (asserts! (< calculated-age u25) ERR-INVALID-AGE) ;; Reasonable upper bound
    (asserts! (is-none (get-age-verification subject)) ERR-ALREADY-VERIFIED)

    (map-set age-verifications
      { subject: subject }
      {
        birth-date: birth-date,
        verified-age: calculated-age,
        verification-date: block-height,
        verification-method: method,
        verifier: verifier,
        confidence-level: confidence,
        expires: (+ block-height u52560) ;; Expires in ~1 year
      }
    )

    ;; Set default age permissions
    (map-set age-permissions
      { subject: subject, age-gate: AGE-THRESHOLD-13 }
      {
        permitted: (>= calculated-age AGE-THRESHOLD-13),
        verification-required: true,
        last-checked: block-height,
        notes: "default-13-gate"
      }
    )

    (map-set age-permissions
      { subject: subject, age-gate: AGE-THRESHOLD-16 }
      {
        permitted: (>= calculated-age AGE-THRESHOLD-16),
        verification-required: true,
        last-checked: block-height,
        notes: "default-16-gate"
      }
    )

    (ok calculated-age)
  )
)

(define-public (update-age-verification (subject principal) (new-birth-date uint) (method (string-ascii 50)))
  (let ((verifier tx-sender))
    (asserts! (is-eq verifier (var-get verification-authority)) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-verification-method method) ERR-VERIFICATION-FAILED)
    (asserts! (is-some (get-age-verification subject)) ERR-NOT-FOUND)

    (let ((new-age (calculate-current-age new-birth-date)))
      (map-set age-verifications
        { subject: subject }
        {
          birth-date: new-birth-date,
          verified-age: new-age,
          verification-date: block-height,
          verification-method: method,
          verifier: verifier,
          confidence-level: (calculate-confidence-level method),
          expires: (+ block-height u52560)
        }
      )

      (ok new-age)
    )
  )
)

(define-public (set-content-rating (content-id (string-ascii 100)) (minimum-age uint) (rating-system (string-ascii 20)) (content-type (string-ascii 50)) (risk-level uint))
  (begin
    (asserts! (is-eq tx-sender (var-get verification-authority)) ERR-NOT-AUTHORIZED)
    (asserts! (<= minimum-age u21) ERR-INVALID-AGE)
    (asserts! (<= risk-level u5) ERR-INVALID-AGE)

    (map-set content-ratings
      { content-id: content-id }
      {
        minimum-age: minimum-age,
        rating-system: rating-system,
        content-type: content-type,
        risk-level: risk-level
      }
    )

    (ok true)
  )
)

(define-public (check-access-eligibility (subject principal) (content-id (string-ascii 100)))
  (let (
    (content-info (get-content-rating content-id))
    (age-info (get-age-verification subject))
  )
    (match content-info
      rating (match age-info
        verification (ok (>= (get verified-age verification) (get minimum-age rating)))
        (ok false) ;; Not age verified
      )
      (ok true) ;; No content rating
    )
  )
)

(define-public (renew-verification (subject principal))
  (match (get-age-verification subject)
    verification (begin
      (map-set age-verifications
        { subject: subject }
        (merge verification {
          expires: (+ block-height u52560),
          verification-date: block-height
        })
      )
      (ok true)
    )
    ERR-NOT-FOUND
  )
)

;; Admin functions
(define-public (set-verification-authority (new-authority principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set verification-authority new-authority)
    (ok true)
  )
)
