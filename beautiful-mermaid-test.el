;;; beautiful-mermaid-test.el --- ERT test suite for beautiful-mermaid.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 scturtle
;; Author: scturtle <scturtle@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: tools, tests
;; SPDX-License-Identifier: MIT

;; Independent, self-contained E2E test runner for beautiful-mermaid.el.
;; It loads the implementation from the same directory and defines
;; ~50 ERT tests in three groups -- all of them end-to-end: every
;; test drives the public render API (or the interactive commands)
;; and asserts on the final output.  No internal function is called.
;;
;;   A. Rendering -- directions, profiles, bundling, CJK, config knobs
;;   B. Goldens   -- byte-exact regression locks (all TS-verified diagrams)
;;   C. API       -- interactive commands
;;   D. Org       -- src-block overlay toggle and org-babel execution
;;
;; Run from a shell (no setup required):
;;
;;   emacs -Q --batch -l beautiful-mermaid-test.el -f ert-run-tests-batch-and-exit
;;
;; Interactively:
;;
;;   M-x load-file RET beautiful-mermaid-test.el RET
;;   M-x ert RET RET          ; run everything
;;
;; The goldens in group B were captured from outputs that matched the
;; TypeScript renderer (src/ascii) character for character, after
;; replacing the arrow glyphs that fall outside the covered font set
;; (unicode.txt): ► ◄ -> ▶ ◀ (▲▼ stay, the TS renderer already draws
;; them), and the diagonal triangles ◤◥◣◢ -> ↖↗↘↙ (no solid diagonals
;; in the covered set).  They lock both the Elisp implementation and
;; the TS correspondence.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'org)

;;; ---------------------------------------------------------------------------
;;; Load the implementation
;;; ---------------------------------------------------------------------------

;; Load beautiful-mermaid.el from this file's directory, both at
;; compile time (so the byte compiler knows every function and
;; variable) and at run time.

(eval-and-compile
  (let* ((me (or load-file-name buffer-file-name default-directory))
         (dir (file-name-directory (file-truename me))))
    (unless (featurep 'beautiful-mermaid)
      (add-to-list 'load-path dir)
      (require 'beautiful-mermaid))))


;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun bm-test--render (src &optional profile)
  "Render SRC under PROFILE (default `full') with triangle arrows
(the default `bm-arrow-style': solid triangles stay closest to the
TS renderer's solid arrow family)."
  (let ((bm-char-profile (or profile 'full))
        (bm-arrow-style 'triangle))
    (beautiful-mermaid-render src)))

(defun bm-test--lines (s)
  (split-string s "\n"))

(defun bm-test--rstrip (s)
  "Truncate trailing blanks on every line of S (comparison normalize)."
  (mapconcat (lambda (l) (replace-regexp-in-string "[ \t]+\\'" "" l))
             (bm-test--lines s) "\n"))

(defun bm-test--contains-none-of (s chars)
  "Non-nil when no character in CHARS occurs in S."
  (not (catch 'found
         (dolist (ch chars)
           (when (string-match-p (string ch) s) (throw 'found t))))))

(defconst bm-test--flip-map
  '((?▲ . ?▼) (?▼ . ?▲) (?↑ . ?↓) (?↓ . ?↑)
    (?↖ . ?↙) (?↙ . ?↖) (?↗ . ?↘) (?↘ . ?↗)
    (?┌ . ?└) (?└ . ?┌) (?┐ . ?┘) (?┘ . ?┐)
    (?╔ . ?╚) (?╚ . ?╔) (?╗ . ?╝) (?╝ . ?╗)
    (?┬ . ?┴) (?┴ . ?┬))
  "Vertical-flip character remapping, hard-coded in the test so the
invariant below is checked against an independent copy.")

(defun bm-test--vflip (s)
  "Vertical flip of S, remapping direction chars.
This mirrors the BT pipeline's final step; used to pin the invariant
\"BT renders exactly like TD plus a flip\"."
  (mapconcat
   (lambda (line)
     (apply #'string
            (mapcar (lambda (ch) (or (cdr (assq ch bm-test--flip-map)) ch))
                    line)))
   (nreverse (bm-test--lines s)) "\n"))

(defun bm-test--arrowhead-count (out)
  "Count thin arrowheads of any direction in OUT."
  (apply #'+ (mapcar (lambda (ch) (cl-count ch out))
                     '(?↑ ?↓ ?← ?→ ?▲ ?▼ ?◀ ?▶ ?↖ ?↗ ?↘ ?↙))))

;;; ---------------------------------------------------------------------------
;;; A. Rendering behavior
;;; ---------------------------------------------------------------------------

(ert-deftest bm-test-render-td-vs-lr-arrows ()
  (should (string-match-p "▼" (bm-test--render "graph TD\n  A --> B")))
  (should (string-match-p "▶" (bm-test--render "graph LR\n  A --> B"))))

(ert-deftest bm-test-render-lines-are-rectangular ()
  (dolist (src '("graph TD\n  A --> B --> C"
                 "graph LR\n  A[Start] --> B{Q} --> C"
                 "graph TD\n  A -->|lbl| B\n  B -.-> C[结束]\n  C ==> D"))
    (let* ((out (bm-test--render src))
           (widths (mapcar #'string-width (bm-test--lines out))))
      (should (< 0 (length widths)))
      (should (cl-every (lambda (w) (= w (car widths))) widths))
      (should-not (string-suffix-p "\n" out)))))

(ert-deftest bm-test-render-bt-is-td-flipped ()
  "BT output is exactly the TD output flipped vertically with
direction characters remapped (bends, box starts, arrowheads)."
  (let* ((td (bm-test--render
              "graph TD\n  A[Alpha] --> B[Beta]\n  B --> C[Gamma]"))
         (bt (bm-test--render
              "graph BT\n  A[Alpha] --> B[Beta]\n  B --> C[Gamma]")))
    (should (equal (bm-test--vflip td) bt))))

(ert-deftest bm-test-render-rl-same-as-lr ()
  ;; the TS renderer treats RL as LR; so do we
  (should (equal (bm-test--render "graph RL\n  A[x] --> B[y] --> C[z]")
                 (bm-test--render "graph LR\n  A[x] --> B[y] --> C[z]"))))

(ert-deftest bm-test-render-all-12-shapes-both-profiles ()
  (let ((src (concat "graph LR\n"
                     "  A1[a] --> A2(b) --> A3{c} --> A4([d]) --> A5((e)) --> A6[[f]]\n"
                     "  A6 --> A7(((g))) --> A8{{h}} --> A9[(i)] --> A10>j] --> A11[/k\\]\n"
                     "  A11 --> A12[\\l/]")))
    (dolist (profile '(safe full))
      (let ((out (bm-test--render src profile)))
        (should (< 0 (length out)))
        (dolist (label '("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l"))
          (should (string-match-p (concat "[^[:alnum:]]" label "[^[:alnum:]]")
                                  out)))))))

(ert-deftest bm-test-render-edge-style-chars ()
  ;; safe: dotted . : -- thick = double-line
  (should (string-match-p "\\."
                         (bm-test--render "graph LR\n  A -.-> B" 'safe)))
  (should (string-match-p ":"
                         (bm-test--render "graph TD\n  A -.-> B" 'safe)))
  (should (string-match-p "═"
                         (bm-test--render "graph LR\n  A ==> B" 'safe)))
  (should (string-match-p "║"
                         (bm-test--render "graph TD\n  A ==> B" 'safe)))
  ;; full: the TS glyphs
  (should (string-match-p "┄" (bm-test--render "graph LR\n  A -.-> B" 'full)))
  (should (string-match-p "┆" (bm-test--render "graph TD\n  A -.-> B" 'full)))
  (should (string-match-p "┃" (bm-test--render "graph TD\n  A ==> B" 'full))))

(ert-deftest bm-test-render-edge-labels ()
  ;; pipe form: label occupies its own line between the boxes
  (let ((out (bm-test--render "graph TD\n  A -->|yes| B")))
    (should (member "yes" (mapcar #'string-trim (bm-test--lines out)))))
  ;; inline form
  (should (string-match-p "message"
                          (bm-test--render "graph LR\n  A -- message --> B"))))

(ert-deftest bm-test-render-self-loop ()
  (let ((out (bm-test--render "graph LR\n  A[Loop] --> A")))
    (should (string-match-p "Loop" out))))

(ert-deftest bm-test-render-cycle ()
  (let ((out (bm-test--render "graph TD\n  A --> B --> C --> A")))
    (should (string-match-p "A" out))
    (should (string-match-p "B" out))
    (should (string-match-p "C" out))))

(ert-deftest bm-test-render-bidirectional ()
  (let ((out (bm-test--render "graph LR\n  A <--> B")))
    (should (string-match-p "▶" out))
    (should (string-match-p "◀" out))))

(ert-deftest bm-test-render-multiline-label ()
  (let* ((out (bm-test--render "graph TD\n  A[\"alpha<br>beta\"] --> B[x]"))
         (lines (bm-test--lines out))
         (pos-a (cl-position-if
                 (lambda (l) (string-match-p "alpha" l)) lines))
         (pos-b (cl-position-if
                 (lambda (l) (string-match-p "beta" l)) lines)))
    (should pos-a)
    (should pos-b)
    (should (= 1 (- pos-b pos-a)))))       ; consecutive rows

(ert-deftest bm-test-render-fan-in-bundle ()
  "Three plain edges into one node share a single arrowhead; a
junction character marks the merge above the target."
  (let ((out (bm-test--render "graph TD\n  A --> D[Done]\n  B --> D\n  C --> D")))
    (should (= 1 (bm-test--arrowhead-count out)))
    (should (string-match-p "[┼┬├┤]" out))
    (should (string-match-p "Done" out))))

(ert-deftest bm-test-render-label-prevents-bundle ()
  "A labelled edge never bundles: the two edges get separate paths
and separate arrowheads."
  (let ((out (bm-test--render "graph TD\n  A -->|x| D\n  B --> D")))
    (should (= 2 (bm-test--arrowhead-count out))))
  ;; without the label the same two edges DO bundle
  (let ((out (bm-test--render "graph TD\n  A --> D\n  B --> D")))
    (should (= 1 (bm-test--arrowhead-count out)))))

(ert-deftest bm-test-render-fan-out-bundle ()
  (let ((out (bm-test--render "graph TD\n  S[Src] --> A\n  S --> B")))
    (should (= 2 (bm-test--arrowhead-count out)))  ; one per target
    (should (string-match-p "[├┬┼]" out))
    (should (string-match-p "Src" out))))

(ert-deftest bm-test-render-cjk-contiguous-and-aligned ()
  (let ((out (bm-test--render "graph LR\n  A[开始] --> B[处理过程]" 'safe)))
    ;; wide glyphs render contiguously -- no injected padding between
    ;; characters and none of the absorbed cells become stray spaces
    (should (string-match-p "开始" out))
    (should (string-match-p "处理过程" out))
    ;; the box frame hugs the label with exactly one pad space
    (should (string-match-p "│ 处理过程 │" out))
    ;; every line has the same display width (borders align)
    (let ((widths (mapcar #'string-width (bm-test--lines out))))
      (should (cl-every (lambda (w) (= w (car widths))) widths)))))

(ert-deftest bm-test-render-config-padding ()
  ;; inter-node spacing follows bm-padding-x
  (let ((narrow (let ((bm-padding-x 3) (bm-padding-y 3))
                  (bm-test--render "graph LR\n  A --> B")))
        (wide   (let ((bm-padding-x 9) (bm-padding-y 9))
                  (bm-test--render "graph LR\n  A --> B"))))
    (should (< (string-width narrow) (string-width wide))))
  ;; interior padding follows bm-box-padding
  (let ((p1 (let ((bm-box-padding 1))
              (bm-test--render "graph LR\n  A[x] --> B")))
        (p3 (let ((bm-box-padding 3))
              (bm-test--render "graph LR\n  A[x] --> B"))))
    (should (< (string-width p1) (string-width p3)))))

(defconst bm-test--profile-diagram
  (concat "graph TD\n"
          "  A(rounded) -.-> B[[subroutine]]\n"
          "  B ==> C{{hexagon}}\n"
          "  C --> D[(cylinder)]\n"
          "  D --> E[/trapezoid\\]\n"
          "  A --> F{diamond}\n"
          "  A --> G[box]")
  "Diagram touching every char class that differs between profiles.")

(ert-deftest bm-test-render-safe-profile-charset-policy ()
  "The safe profile never emits characters outside the covered font
set (unicode.txt): no rounded corners, dotted/dashed lines, heavy
lines, black pointers, diagonal triangles, or unsupported markers."
  (let ((out (bm-test--render bm-test--profile-diagram 'safe)))
    (should (bm-test--contains-none-of
             out
             '(?╭ ?╮ ?╰ ?╯            ; rounded / cylinder corners
               ?┄ ?┆                  ; dotted lines
               ?━ ?┃                  ; heavy lines
               ?◄ ?►                  ; black pointers
               ?◤ ?◥ ?◣ ?◢            ; diagonal triangles
               ?◇ ?◯ ?◎               ; markers
               ?╟ ?╢                  ; subroutine flanks
               ?⌜ ?⌝ ?⌞ ?⌟)))))      ; hexagon corners

(ert-deftest bm-test-render-full-profile-uses-ts-chars ()
  (let ((out (bm-test--render bm-test--profile-diagram 'full)))
    (should (string-match-p "╭" out))     ; rounded corners
    (should (string-match-p "╟" out))     ; subroutine flanks
    (should (string-match-p "⌜" out))     ; hexagon corners
    (should (string-match-p "┆" out))     ; dotted line (vertical in TD)
    (should (string-match-p "┃" out))))   ; thick line (vertical in TD)

(ert-deftest bm-test-render-arrow-style-option ()
  "`triangle' is the default; the `arrow' option switches to thin
arrowheads in every direction."
  (let ((out (let ((bm-char-profile 'safe))
               (beautiful-mermaid-render "graph LR\n  A --> B --> C"))))
    (should (string-match-p "▶" out))
    (should-not (string-match-p "→" out)))
  (let ((out (let ((bm-char-profile 'safe)
                   (bm-arrow-style 'arrow))
               (beautiful-mermaid-render "graph LR\n  A --> B --> C"))))
    (should (string-match-p "→" out))
    (should-not (string-match-p "▶" out))))

;;; ---------------------------------------------------------------------------
;;; B. Byte-exact goldens: all 27 TS-verified diagrams (regression locks)
;;; ---------------------------------------------------------------------------
;; Every constant below is the exact renderer output for the diagram in
;; the corresponding test.  All of them matched the TypeScript renderer
;; (src/ascii) byte for byte with the full profile, after replacing the
;; arrow glyphs that fall outside the covered font set (unicode.txt):
;; ► ◄ -> ▶ ◀ (▲▼ stay, the TS renderer already draws them), and the
;; diagonal triangles ◤◥◣◢ -> ↖↗↘↙ (no solid diagonals in the covered
;; set).  Any change in layout, routing, or drawing breaks these tests
;; on purpose.  Together the diagrams cover: every node shape, every
;; line style, edge labels in both syntaxes, bidirectional and open
;; edges, chains, cycles, self loops, back edges, fan-in and fan-out
;; bundling (solid, dotted and thick), label-blocks-bundling, the
;; flowchart keyword, multi-line labels, node groups (ampersand),
;; multi-root and standalone graphs, skip-level edges, LR edge labels,
;; collision shifting (deep tree), the RL and BT directions, and CJK
;; width handling (safe profile, last case).

(defconst bm-test--golden-all-shapes
  "                                                                                                                                                                                                              \n┌───────────┐     ╭─────────╮     ◇─────────◇      (──────────)     ◯────────◯      ╟─────────────╢     ◎───────────────◎     ⌜─────────⌝     ╭──────────╮     ▷──────┐     /───────────\\     ┌──────────────┐\n│           │     │         │     │         │      │          │     │        │      │             │     │               │     │         │     │          │     │      │     │           │     │              │\n│ Rectangle ├────▶│ Rounded ├────▶│ Diamond ├─────▶│ Stadium  ├────▶│ Circle ├─────▶│  Subroutine ├────▶│ Double Circle ├────▶│ Hexagon ├────▶│ Database ├────▶│ Flag ├────▶│ Trapezoid ├────▶│ Inverse Trap │\n│           │     │         │     │         │      │          │     │        │      │             │     │               │     │         │     │          │     │      │     │           │     │              │\n│           │     │         │     │         │      │          │     │        │      │             │     │               │     │         │     │          │     │      │     │           │     │              │\n└───────────┘     ╰─────────╯     ◇─────────◇      (──────────)     ◯────────◯      ╟─────────────╢     ◎───────────────◎     ⌞─────────⌟     ╰──────────╯     ▷──────┘     └───────────┘     \\──────────────/")

(ert-deftest bm-test-golden-all-shapes ()
  "all 12 node shapes chained (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-all-shapes)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A[Rectangle] --> B(Rounded)\n  B --> C{Diamond}\n  C --> D([Stadium])\n  D --> E((Circle))\n  E --> F[[Subroutine]]\n  F --> G(((Double Circle)))\n  G --> H{{Hexagon}}\n  H --> I[(Database)]\n  I --> J>Flag]\n  J --> K[/Trapezoid\\]\n  K --> L[\\Inverse Trap/]")))))


(defconst bm-test--golden-back-edge
  "┌───┐          \n│   │          \n│ A │◀─┐       \n│   │  │       \n└───┘  │       \n  │    │       \n  │    │       \n  ├────┼────┐  \n  │    │    │  \n  ▼    │    ▼  \n┌───┐  │  ┌───┐\n│   │  │  │   │\n│ B │  │  │ D │\n│   │  │  │   │\n└─┬─┘  │  └───┘\n  │    │       \n  │    │       \n  │    │       \n  │    │       \n  ▼    │       \n┌───┐  │       \n│   │  │       \n│ C ├──┘       \n│   │          \n└───┘          ")

(ert-deftest bm-test-golden-back-edge ()
  "back edge C --> A plus a forward edge (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-back-edge)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A --> B\n  B --> C\n  C --> A\n  A --> D")))))


(defconst bm-test--golden-bidi
  "┌────────┐      ┌────────┐           ┌─────────┐      ┌─────────┐\n│        │      │        │           │         │      │         │\n│ Client ◀sync─▶│ Server ◀┄heartbeat▶│ Monitor ◀data━▶│ Storage │\n│        │      │        │           │         │      │         │\n└────────┘      └────────┘           └─────────┘      └─────────┘")

(ert-deftest bm-test-golden-bidi ()
  "bidirectional labelled edges in all three styles (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-bidi)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A[Client] <-->|sync| B[Server]\n  B <-.->|heartbeat| C[Monitor]\n  C <==>|data| D[Storage]")))))


(defconst bm-test--golden-bt-flow
  "┌───────┐     ┌──────┐\n│       │     │      │\n│   Go  │     │ Stop │\n│       │     │      │\n└───────┘     └──────┘\n    ▲             ▲   \n    │             │   \n    │             │   \n   yes            │   \n    │             │   \n◇───┴───◇        no   \n│       │         │   \n│   Q   ├─────────┘   \n│       │             \n◇───────◇             \n    ▲                 \n    │                 \n    │                 \n    │                 \n    │                 \n┌───┴───┐             \n│       │             \n│ Start │             \n│       │             \n└───────┘             ")

(ert-deftest bm-test-golden-bt-flow ()
  "BT direction: labelled branch (verifies the vertical flip against TS)."
  (should (equal (bm-test--rstrip bm-test--golden-bt-flow)
                 (bm-test--rstrip
                  (bm-test--render "graph BT\n  A[Start] --> B{Q}\n  B -->|yes| C[Go]\n  B -->|no| D[Stop]")))))


(defconst bm-test--golden-chain
  "┌───┐     ┌───┐     ┌───┐     ┌───┐\n│   │     │   │     │   │     │   │\n│ A ├────▶│ B ├────▶│ C ├────▶│ D │\n│   │     │   │     │   │     │   │\n└───┘     └───┘     └───┘     └───┘")

(ert-deftest bm-test-golden-chain ()
  "plain four-node chain (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-chain)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A --> B --> C --> D")))))


(defconst bm-test--golden-cross-level
  "┌───┐     ┌───┐\n│   │     │   │\n│ A ├────▶│ B │\n│   │     │   │\n└─┬─┘     └─┬─┘\n  │         │  \n  │         │  \n  │         │  \n  │         │  \n  │         ▼  \n  │       ┌───┐\n  │       │   │\n  └──────▶│ C │\n          │   │\n          └───┘")

(ert-deftest bm-test-golden-cross-level ()
  "skip-level edge A --> C alongside A --> B --> C (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-cross-level)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A --> B --> C\n  A --> C")))))


(defconst bm-test--golden-cycle
  "┌───┐     ┌───┐     ┌───┐\n│   │     │   │     │   │\n│ A ├────▶│ B ├────▶│ C │\n│   │     │   │     │   │\n└───┘     └───┘     └─┬─┘\n  ▲                   │  \n  └───────────────────┘  ")

(ert-deftest bm-test-golden-cycle ()
  "three-node cycle (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-cycle)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A --> B\n  B --> C\n  C --> A")))))


(defconst bm-test--golden-deep-tree
  "┌──────┐                              \n│      │                              \n│ Root │                              \n│      │                              \n└──────┘                              \n    │                                 \n    │                                 \n    ├──────────┐                      \n    │          │                      \n    ▼          ▼                      \n┌──────┐     ┌───┐                    \n│      │     │   │                    \n│  B   │     │ C │                    \n│      │     │   │                    \n└──────┘     └───┘                    \n    │          │                      \n    │          │                      \n    ├──────────┼─────────┬─────────┐  \n    │          │         │         │  \n    ▼          ▼         ▼         ▼  \n┌──────┐     ┌───┐     ┌───┐     ┌───┐\n│      │     │   │     │   │     │   │\n│  D   │     │ E │     │ F │     │ G │\n│      │     │   │     │   │     │   │\n└──────┘     └───┘     └───┘     └───┘")

(ert-deftest bm-test-golden-deep-tree ()
  "two-level binary tree via node groups; collision shifting (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-deep-tree)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Root] --> B & C\n  B --> D & E\n  C --> F & G")))))


(defconst bm-test--golden-diamond
  "┌────────┐             \n│        │             \n│ Start  │             \n│        │             \n└────┬───┘             \n     │                 \n     │                 \n     ├──────┐          \n     │      │          \n     ▼      │          \n◇────────◇  │          \n│        │  │          \n│ Check  ├──┼──────┐   \n│        │  │      │   \n◇────┬───◇  │    fail  \n     │      │      │   \n   pass     │      │   \n     │      │      │   \n     │      │      │   \n     ▼      │      ▼   \n┌────────┐  │  ┌──────┐\n│        │  │  │      │\n│ Deploy │  │  │ Fix  │\n│        │  │  │      │\n└────────┘  │  └───┬──┘\n            │      │   \n            └──────┘   ")

(ert-deftest bm-test-golden-diamond ()
  "labelled branch with back edge; fan-in and fan-out bundling (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-diamond)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Start] --> B{Check}\n  B -->|pass| C[Deploy]\n  B -->|fail| D[Fix]\n  D --> B")))))


(defconst bm-test--golden-diamonds2
  " (────────────)              \n │            │              \n │  Kickoff   │              \n │            │              \n (──────┬─────)              \n       │                     \n       │                     \n       ├─────────┐           \n       │         │           \n       │▼        │           \n ◇────────────◇  │           \n │            │  │           \n │ All good?  ├──┼──────┐    \n │            │  │      │    \n ◇─────┬──────◇  │     no    \n       │         │      │    \n      yes        │      │    \n       │         │      │    \n       │         │      │    \n       ▼         │      ▼    \n ┌────────────┐  │  ┌───────┐\n │            │  │  │       │\n │  Validate  │  │  │ Retry │\n │            │  │  │       │\n └────────────┘  │  └───┬───┘\n                 │      │    \n                 └──────┘    ")

(ert-deftest bm-test-golden-diamonds2 ()
  "flowchart keyword, stadium/diamond nodes, back edge (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-diamonds2)
                 (bm-test--rstrip
                  (bm-test--render "flowchart TD\n  S([Kickoff]) --> P{All good?}\n  P -- yes --> V[Validate]\n  P -- no --> R[Retry]\n  R --> P")))))


(defconst bm-test--golden-dotted-bundle
  "┌──────┐     ┌───┐     ┌───┐\n│      │     │   │     │   │\n│  A   │     │ B │     │ C │\n│      │     │   │     │   │\n└───┬──┘     └─┬─┘     └─┬─┘\n    ┆          ┆         ┆  \n    ┆          ┆         ┆  \n    ├┄┄┄┄┄┄┄┄┄┄┘┄┄┄┄┄┄┄┄┄┘  \n    ┆                       \n    ▼                       \n┌──────┐                    \n│      │                    \n│ Done │                    \n│      │                    \n└──────┘                    ")

(ert-deftest bm-test-golden-dotted-bundle ()
  "three dotted edges fan-in into one node (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-dotted-bundle)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A -.-> D[Done]\n  B -.-> D\n  C -.-> D")))))


(defconst bm-test--golden-label-vs-bundle
  "┌──────┐     ┌───┐\n│      │     │   │\n│  A   │     │ B │\n│      │     │   │\n└───┬──┘     └─┬─┘\n    │          │  \n    x          │  \n    │          │  \n    │          │  \n    ▼          │  \n┌──────┐       │  \n│      │       │  \n│ Done │◀──────┘  \n│      │          \n└──────┘          ")

(ert-deftest bm-test-golden-label-vs-bundle ()
  "a labelled edge does not bundle: separate arrowheads (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-label-vs-bundle)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A -->|x| D[Done]\n  B --> D")))))


(defconst bm-test--golden-labels
  "◇──────────◇             \n│          │             \n│ Decision ├─────────┐   \n│          │         │   \n◇─────┬────◇        No   \n      │              │   \n     Yes             │   \n      │              │   \n      │              │   \n      ▼              ▼   \n┌──────────┐     ┌──────┐\n│          │     │      │\n│  Action  │     │ Skip │\n│          │     │      │\n└─────┬────┘     └──────┘\n      │                  \n      │                  \n      │                  \n      │                  \n      ▼                  \n◯──────────◯             \n│          │             \n│   End    │             \n│          │             \n◯──────────◯             ")

(ert-deftest bm-test-golden-labels ()
  "diamond source with two labelled edges, circle target (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-labels)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A{Decision} -->|Yes| B[Action]\n  A -->|No| C[Skip]\n  B --> D((End))")))))


(defconst bm-test--golden-lr-labels
  "┌───┐       ┌───┐     ┌───┐      ┌─────┐\n│   │       │   │     │   │      │     │\n│ A ├─first▶│ B ├────▶│ C ├slow┄▶│ End │\n│   │       │   │     │   │      │     │\n└───┘       └───┘     └───┘      └─────┘")

(ert-deftest bm-test-golden-lr-labels ()
  "edge labels on horizontal edges, dotted tail (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-lr-labels)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A -->|first| B --> C\n  C -. slow .-> D[End]")))))


(defconst bm-test--golden-multi-amp
  "┌─────┐     ┌───┐\n│     │     │   │\n│  A  │     │ B │\n│     │     │   │\n└──┬──┘     └─┬─┘\n   │          │  \n   │          │  \n   ├──────────┤  \n   │          │  \n   ▼          ▼  \n┌─────┐     ┌───┐\n│     │     │   │\n│  C  │     │ D │\n│     │     │   │\n└──┬──┘     └───┘\n   │             \n   │             \n   │             \n   │             \n   ▼             \n┌─────┐          \n│     │          \n│ End │          \n│     │          \n└─────┘          ")

(ert-deftest bm-test-golden-multi-amp ()
  "A & B --> C & D node groups (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-multi-amp)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A & B --> C & D\n  C --> E[End]")))))


(defconst bm-test--golden-multi-root
  "┌───────┐     ┌───────┐\n│       │     │       │\n│ Alpha │     │ Gamma │\n│       │     │       │\n└───┬───┘     └───┬───┘\n    │             │    \n    │             │    \n    │             │    \n    │             │    \n    ▼             ▼    \n┌───────┐     ┌───────┐\n│       │     │       │\n│  Beta │     │ Delta │\n│       │     │       │\n└───────┘     └───────┘")

(ert-deftest bm-test-golden-multi-root ()
  "two disconnected subgraphs: multi-root placement (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-multi-root)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Alpha] --> B[Beta]\n  C[Gamma] --> D[Delta]")))))


(defconst bm-test--golden-multiline
  "┌───────┐     ┌───┐\n│       │     │   │\n│       │     │   │\n│ line1 ├────▶│ x │\n│ line2 │     │   │\n│       │     │   │\n└───────┘     └───┘")

(ert-deftest bm-test-golden-multiline ()
  "two-line label via <br/> (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-multiline)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A[\"line1<br/>line2\"] --> B[x]")))))


(defconst bm-test--golden-parallel
  "┌───────┐              \n│       │              \n│ Start │              \n│       │              \n└───────┘              \n    │                  \n    │                  \n    ├─────────────┐    \n    │             │    \n    ▼             ▼    \n┌───────┐     ┌───────┐\n│       │     │       │\n│  Left │     │ Right │\n│       │     │       │\n└───┬───┘     └───┬───┘\n    │             │    \n    │             │    \n    ├─────────────┘    \n    │                  \n    ▼                  \n┌───────┐              \n│       │              \n│  Join │              \n│       │              \n└───────┘              ")

(ert-deftest bm-test-golden-parallel ()
  "parallel branches merging into one node; bundling (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-parallel)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Start] --> B[Left]\n  A --> C[Right]\n  B --> D[Join]\n  C --> D")))))


(defconst bm-test--golden-rl-flow
  "┌─────┐     ◇─────◇     ┌───────┐\n│     │     │     │     │       │\n│ One ├────▶│ Two ├────▶│ Three │\n│     │     │     │     │       │\n└─────┘     ◇─────◇     └───────┘")

(ert-deftest bm-test-golden-rl-flow ()
  "RL direction renders exactly as LR (matches TS)."
  (should (equal (bm-test--rstrip bm-test--golden-rl-flow)
                 (bm-test--rstrip
                  (bm-test--render "graph RL\n  A[One] --> B{Two}\n  B --> C[Three]")))))


(defconst bm-test--golden-selfloop
  "┌──────┐  \n│      │  \n│ Loop │◀┐\n│      │ │\n└───┬──┘ │\n    │    │\n    │    │\n    ├────┘\n    │     \n    ▼     \n┌──────┐  \n│      │  \n│ Next │  \n│      │  \n└──────┘  ")

(ert-deftest bm-test-golden-selfloop ()
  "self loop plus a forward edge (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-selfloop)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Loop] --> A\n  A --> B[Next]")))))


(defconst bm-test--golden-shapes-lr
  "┌───────────┐     ╭─────────╮     ◇─────────◇      (──────────)     ◯────────◯\n│           │     │         │     │         │      │          │     │        │\n│ Rectangle ├────▶│ Rounded ├────▶│ Diamond ├─────▶│ Stadium  ├────▶│ Circle │\n│           │     │         │     │         │      │          │     │        │\n└───────────┘     ╰─────────╯     ◇─────────◇      (──────────)     ◯────────◯")

(ert-deftest bm-test-golden-shapes-lr ()
  "five basic shapes chained (LR)."
  (should (equal (bm-test--rstrip bm-test--golden-shapes-lr)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A[Rectangle] --> B(Rounded)\n  B --> C{Diamond}\n  C --> D([Stadium])\n  D --> E((Circle))")))))


(defconst bm-test--golden-simple-td
  "┌─────────┐\n│         │\n│  Start  │\n│         │\n└────┬────┘\n     │     \n     │     \n     │     \n     │     \n     ▼     \n┌─────────┐\n│         │\n│ Process │\n│         │\n└────┬────┘\n     │     \n     │     \n     │     \n     │     \n     ▼     \n┌─────────┐\n│         │\n│   End   │\n│         │\n└─────────┘")

(ert-deftest bm-test-golden-simple-td ()
  "vertical chain (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-simple-td)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Start] --> B[Process] --> C[End]")))))


(defconst bm-test--golden-standalone
  "┌──────────┐\n│          │\n│ Only One │\n│          │\n└──────────┘")

(ert-deftest bm-test-golden-standalone ()
  "a lone node still renders a box (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-standalone)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Only One]")))))


(defconst bm-test--golden-styles
  "┌────────┐                   \n│        │                   \n│ Solid  │                   \n│        │                   \n└────────┘                   \n     │                       \n     │                       \n     ├────────────────┐      \n     │                │      \n     ▼                │      \n┌────────┐     ┌────────────┐\n│        │     │            │\n│ Dotted │     │ Plain line │\n│        │     │            │\n└────┬───┘     └────────────┘\n     ┆                       \n     ┆                       \n     ┆                       \n     ┆                       \n     ▼                       \n┌────────┐                   \n│        │                   \n│ Thick  │                   \n│        │                   \n└────┬───┘                   \n     ┃                       \n     ┃                       \n     ┃                       \n     ┃                       \n     ▼                       \n┌────────┐                   \n│        │                   \n│  Done  │                   \n│        │                   \n└────────┘                   ")

(ert-deftest bm-test-golden-styles ()
  "solid, dotted, thick and open edges (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-styles)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Solid] --> B[Dotted]\n  B -.-> C[Thick]\n  C ==> D[Done]\n  A --- E[Plain line]")))))


(defconst bm-test--golden-textarrow
  "┌───────┐             \n│       │             \n│ Start ├━━━━━━━━━┐   \n│       │         ┃   \n└───┬───┘       sure  \n    │             ┃   \n   yes            ┃   \n    │             ┃   \n    │             ┃   \n    ▼             ▼   \n┌───────┐     ┌──────┐\n│       │     │      │\n│   Go  │     │ Rush │\n│       │     │      │\n└───┬───┘     └──────┘\n    ┆                 \n  maybe               \n    ┆                 \n    ┆                 \n    ▼                 \n┌───────┐             \n│       │             \n│  Wait │             \n│       │             \n└───────┘             ")

(ert-deftest bm-test-golden-textarrow ()
  "inline-text arrows in all three styles (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-textarrow)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Start] -- yes --> B[Go]\n  B -. maybe .-> C[Wait]\n  A == sure ==> D[Rush]")))))


(defconst bm-test--golden-thick-bundle
  "┌──────┐              \n│      │              \n│ Src  │              \n│      │              \n└──────┘              \n    ┃                 \n    ┃                 \n    ├━━━━━━━━━━━━┐    \n    ┃            ┃    \n    ▼            ▼    \n┌──────┐     ┌───────┐\n│      │     │       │\n│ Left │     │ Right │\n│      │     │       │\n└───┬──┘     └───┬───┘\n    ┃            ┃    \n    ┃            ┃    \n    ├━━━━━━━━━━━━┘    \n    ┃                 \n    ▼                 \n┌──────┐              \n│      │              \n│ Join │              \n│      │              \n└──────┘              ")

(ert-deftest bm-test-golden-thick-bundle ()
  "unlabelled thick edges bundle both ways; double-line chars (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-thick-bundle)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Src] ==> B[Left]\n  A ==> C[Right]\n  B ==> D[Join]\n  C ==> D")))))


(defconst bm-test--golden-thick-bend
  "┌───────┐              \n│       │              \n│  Top  │              \n│       │              \n└───┬───┘              \n    ┃                  \n    ┃                  \n    ┃                  \n    ┃                  \n    ▼                  \n◇───────◇              \n│       │              \n│ Check ├━━━━━━━━━┐    \n│       │         ┃    \n◇───┬───◇        bad   \n    ┃             ┃    \n   ok             ┃    \n    ┃             ┃    \n    ┃             ┃    \n    ▼             ▼    \n┌───────┐     ┌───────┐\n│       │     │       │\n│  Left │     │ Right │\n│       │     │       │\n└───────┘     └───────┘")

(ert-deftest bm-test-golden-thick-bend ()
  "thick edges with labels and a branch (TD)."
  (should (equal (bm-test--rstrip bm-test--golden-thick-bend)
                 (bm-test--rstrip
                  (bm-test--render "graph TD\n  A[Top] ==> B{Check}\n  B ==>|ok| C[Left]\n  B ==>|bad| D[Right]")))))


(defconst bm-test--golden-cjk
  "┌──────┐     ┌──────────┐     ┌──────┐\n│      │     │          │     │      │\n│ 开始 ├────▶│ 处理过程 ├────▶│ 结束 │\n│      │     │          │     │      │\n└──────┘     └──────────┘     └──────┘")

(ert-deftest bm-test-golden-cjk ()
  "CJK wide-glyph absorption and border alignment (safe profile)."
  (should (equal (bm-test--rstrip bm-test--golden-cjk)
                 (bm-test--rstrip
                  (bm-test--render "graph LR\n  A[开始] --> B[处理过程] --> C[结束]" 'safe)))))


;;; ---------------------------------------------------------------------------
;;; C. API
;;; ---------------------------------------------------------------------------

(ert-deftest bm-test-api-render-returns-plain-string ()
  (let ((out (bm-test--render "graph TD\n  A --> B")))
    (should (stringp out))
    (should-not (string-suffix-p "\n" out))   ; no trailing newline
    (should (string-match-p "\n" out))))      ; multi-line

(ert-deftest bm-test-api-render-region-command ()
  (with-temp-buffer
    (insert "graph LR\n  A[Region] --> B[Test]")
    (beautiful-mermaid-render-region (point-min) (point-max)))
  (let ((buf (get-buffer "*mermaid-ascii*")))
    (should (buffer-live-p buf))
    (with-current-buffer buf
      (should (string-match-p "Region" (buffer-string)))
      (should (string-match-p "┌" (buffer-string))))))

(ert-deftest bm-test-api-render-buffer-command ()
  (with-temp-buffer
    (insert "graph TD\n  A[Buffer] --> B")
    (beautiful-mermaid-render-buffer))
  (should (string-match-p "Buffer"
                          (with-current-buffer "*mermaid-ascii*"
                            (buffer-string)))))



;;; ---------------------------------------------------------------------------
;;; D. Org-mode integration
;;; ---------------------------------------------------------------------------

(defconst bm-test--org-block
  "#+begin_src mermaid\n  graph LR\n    A[Alpha] --> B\n#+end_src\n")

(defun bm-test--art-overlays ()
  "All beautiful-mermaid render overlays in the current buffer."
  (cl-remove-if-not
   (lambda (ov) (overlay-get ov 'beautiful-mermaid))
   (overlays-in (point-min) (point-max))))

(ert-deftest bm-test-org-toggle-block ()
  "Toggling covers a mermaid src block with its rendering; toggling
again restores the source."
  (with-temp-buffer
    (org-mode)
    (insert bm-test--org-block)
    (goto-char (point-min))
    (search-forward "Alpha")              ; point inside the block body
    (beautiful-mermaid-org-toggle)
    (let ((ovs (bm-test--art-overlays)))
      (should (= 1 (length ovs)))
      (let ((disp (overlay-get (car ovs) 'display)))
        (should (stringp disp))
        (should (string-match-p "┌" disp))
        (should (string-match-p "Alpha" disp))
        (should (string-match-p "▶" disp))))
    ;; point was parked on the overlay start, second toggle restores
    (beautiful-mermaid-org-toggle)
    (should (null (bm-test--art-overlays)))))

(ert-deftest bm-test-org-toggle-all-blocks ()
  "With C-u the toggle renders every mermaid block, then restores all."
  (with-temp-buffer
    (org-mode)
    (insert bm-test--org-block)
    (insert "between\n")
    (insert "#+begin_src mermaid\n  graph TD\n    C --> D\n#+end_src\n")
    (goto-char (point-min))
    (beautiful-mermaid-org-toggle '(4))
    (should (= 2 (length (bm-test--art-overlays))))
    (beautiful-mermaid-org-toggle '(4))
    (should (null (bm-test--art-overlays)))))

(ert-deftest bm-test-org-toggle-block-keeps-following-text-on-next-line ()
  "The overlay swallows the \"#+end_src\" line terminator, so the
display string must end with a newline -- otherwise the text after
the block continues on the art's last line."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src mermaid\n"
            "  graph TD\n"
            "    X[Source] --> Y[Art]\n"
            "#+end_src\n"
            "\n"
            "blabla\n")
    (goto-char (point-min))
    (search-forward "Source")
    (beautiful-mermaid-org-toggle)
    (let ((ovs (bm-test--art-overlays)))
      (should (= 1 (length ovs)))
      (let ((disp (overlay-get (car ovs) 'display)))
        (should (stringp disp))
        (should (string-suffix-p "\n" disp))))
    ;; and the text after the block is still a separate line
    (should (equal "blabla" (buffer-substring-no-properties
                             (save-excursion
                               (goto-char (point-max))
                               (search-backward "blabla")
                               (line-beginning-position))
                             (save-excursion
                               (goto-char (point-max))
                               (search-backward "blabla")
                               (line-end-position)))))))

(ert-deftest bm-test-org-toggle-outside-block-errors ()
  (with-temp-buffer
    (org-mode)
    (insert "just text\n")
    (should-error (beautiful-mermaid-org-toggle))))

(ert-deftest bm-test-org-toggle-indented-block ()
  "A block nested in a list renders with the art indented to the
block column, keeping the diagram aligned with surrounding text."
  (with-temp-buffer
    (org-mode)
    (insert "- item\n"
            "  #+begin_src mermaid\n"
            "    graph LR\n"
            "      A --> B\n"
            "  #+end_src\n")
    (goto-char (point-min))
    (search-forward "A --> B")
    (beautiful-mermaid-org-toggle)
    (let* ((ovs (bm-test--art-overlays))
           (disp (and ovs (overlay-get (car ovs) 'display))))
      (should (= 1 (length ovs)))
      (should (stringp disp))
      ;; every art line is prefixed with the block's two-space column
      (should (string-prefix-p "  ┌" disp))
      (should (cl-every (lambda (l) (or (string= l "")
                                        (string-prefix-p "  " l)))
                        (bm-test--lines disp))))))

(ert-deftest bm-test-org-babel-mermaid ()
  "The org-babel hook renders a block body to ASCII art; a full
org-babel evaluation round returns the rendering as the result."
  (should (string-match-p "┌" (org-babel-execute:mermaid "graph LR\n  A --> B" nil)))
  (require 'ob)
  (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
            ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
    (with-temp-buffer
      (org-mode)
      (insert bm-test--org-block)
      (goto-char (point-min))
      (search-forward "graph")
      (let ((result (org-babel-execute-src-block)))
        (should (stringp result))
        (should (string-match-p "┌" result))))))

(provide 'beautiful-mermaid-test)
;;; beautiful-mermaid-test.el ends here
