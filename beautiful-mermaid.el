;;; beautiful-mermaid.el --- Render Mermaid flowcharts as Unicode terminal art -*- lexical-binding: t; -*-

;; Copyright (C) 2026 scturtle
;; Author: scturtle <scturtle@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: tools, diagrams, mermaid, ascii
;; URL: https://github.com/scturtle/beautiful-mermaid.el
;; SPDX-License-Identifier: MIT

;; This file is a port of the ASCII renderer in the TypeScript
;; project `beautiful-mermaid' by Craft Docs; it derives in turn from
;; Alexander Grooff's `mermaid-ascii'.  Both are MIT-licensed.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; A single-file Emacs Lisp port of the ASCII/Unicode renderer from
;; `beautiful-mermaid' (https://github.com/lukilabs/beautiful-mermaid), which
;; itself derives from Alexander Grooff's `mermaid-ascii'.
;;
;; This port is deliberately minimal:
;;
;;   * Only flowcharts (`graph TD' / `flowchart LR' ...).  State, sequence,
;;     class, ER and xychart diagrams are rejected with an error.
;;   * Only Unicode box-drawing output (there is no `useAscii' option).
;;   * Only terminal output: `beautiful-mermaid-render' returns a plain
;;     multi-line string.  No colors, no themes, no role canvas.
;;   * No subgraphs, no classDef/style/linkStyle (such lines are parsed
;;     and silently ignored rather than rejected).
;;
;; Kept from the original (they are what make the output good):
;;
;;   * All 12 flowchart node shapes (rectangle, rounded, diamond, circle,
;;     stadium, hexagon, subroutine, doublecircle, cylinder, asymmetric,
;;     trapezoid, trapezoid-alt) — every shape is a box with distinctive
;;     corner characters, so supporting them costs only a lookup table.
;;   * Edge styles: solid `-->', dotted `-.->', thick `==>', open `---'.
;;   * Edge labels (`-->|yes|'), text-embedded labels (`-- yes -->'),
;;     bidirectional arrows (`<-->'), chained edges (A --> B --> C),
;;     parallel links (A & B --> C & D), self loops and back edges.
;;   * The grid layout + A* edge routing engine: each node reserves a
;;     3x3 block on a logical grid; edges are routed with A* between
;;     blocks, preferring straight lines (corner-penalizing heuristic);
;;     crossing line segments merge into junction characters (┼).
;;   * Multi-line labels via `<br>' tags.
;;   * CJK-correct alignment: labels are measured and drawn by display
;;     width (`string-width'), so wide characters align box borders in
;;     the terminal.  (The TypeScript original measures UTF-16 length
;;     and misaligns CJK labels.)
;;
;; Differences from the TypeScript renderer:
;;
;;   * Arrows always come from the safe set: thin arrows → ← ↑ ↓
;;     ↖ ↗ ↘ ↙ (default), or solid triangles ▲ ▼ ◀ ▶ with
;;     `bm-arrow-style' set to `triangle'.  The TS renderer's ► ◄
;;     and ◤ ◥ ◣ ◢ are not in the safe set and never emitted.
;;     The `full' char profile differs from `safe' only in frame
;;     glyphs (rounded corners, dotted/dashed lines); `safe' output
;;     is a pure character substitution of `full' output.
;;
;;       rounded/cylinder corners  ╭╮╰╯  ->  ╔╗╚╝  (with ═║ borders)
;;       dotted lines              ┄ ┆   ->  . :
;;       thick lines               ━ ┃   ->  ═ ║   (bends use ╔╗╚╝)
;;       arrows                    ► ◄   ->  → ←  (thin arrow set)
;;       diagonals                 ◤◥◣◢  ->  ↖↗↘↙
;;       diamond marker            ◇     ->  ◊
;;       circle markers            ◯ ◎   ->  ◌
;;       hexagon corners           ⌜⌝⌞⌟  ->  ╱╲╲╱
;;       subroutine sides          ╟ ╢   ->  ╠ ╣
;;
;;   * Formatting markup (`**bold**', `<sub>', ...) is stripped from
;;     labels instead of being converted to literal `<b>' tags.
;;   * `graph LR; A --> B' (edges on the header line) is accepted.
;;
;; Architecture (mirrors src/ascii/ of the TS project):
;;
;;   parse        bm--parse              regex line parser -> graph struct
;;   layout       bm--layout             grid placement + column/row sizing
;;               + bm--determine-path   A* routing (bm--astar), label lines
;;   draw         bm--draw-graph         layered painting onto a hash canvas
;;               (boxes -> lines -> corners -> arrowheads -> box-starts
;;                -> start arrowheads -> labels)
;;   output       bm--canvas-to-string   rows joined with newlines
;;
;; Usage:
;;
;;   (beautiful-mermaid-render "graph LR\n  A[Start] --> B{Choice}")
;;
;;   Or interactively: mark a region containing mermaid source and run
;;   M-x beautiful-mermaid-render-region.  The diagram appears in the
;;   buffer *mermaid-ascii*.

;;; Code:

(require 'cl-lib)
(require 'subr-x)


;;; ============================= Customization =============================

(defgroup beautiful-mermaid nil
  "Render Mermaid flowcharts as Unicode box-drawing art."
  :group 'tools)

(defcustom bm-char-profile 'safe
  "Character profile for drawing glyphs.

`safe' restricts every drawing character to a small, widely available
set (single-line box chars, double-line box chars, thin arrows U+2190
range, and a few geometric shapes).  Use this when your terminal font
has limited Unicode coverage.

`full' uses the exact frame characters of the TypeScript
beautiful-mermaid renderer (rounded corners, dotted/dashed lines).
Arrows are unaffected by the profile; they always come from the safe
set (see `bm-arrow-style')."
  :type '(choice (const :tag "Safe (limited-coverage fonts)" safe)
                 (const :tag "Full (TS-style frames)" full)))

(defcustom bm-padding-x 5
  "Horizontal spacing between nodes, in character cells."
  :type 'natnum)

(defcustom bm-padding-y 5
  "Vertical spacing between nodes, in character cells."
  :type 'natnum)

(defcustom bm-box-padding 1
  "Padding between a node label and its box border, in cells."
  :type 'natnum)

(defcustom bm-arrow-style 'arrow
  "Arrowhead style used by the `safe' char profile.

`arrow' uses thin arrows (→ ← ↑ ↓ ↖ ↗ ↘ ↙).
`triangle' uses solid triangles (▶ ◀ ▲ ▼)."
  :type '(choice (const arrow) (const triangle)))


;;; ============================ Data structures ============================

(cl-defstruct (bm--node (:constructor bm--node-create))
  id                                ; string; parser identity key
  label                             ; string; may contain newlines
  shape                             ; symbol
  (gx nil) (gy nil)                 ; grid coord (top-left of 3x3 block)
  (dx nil) (dy nil))                ; drawing coord (top-left of box)

(cl-defstruct (bm--edge (:constructor bm--edge-create))
  from to                           ; bm--node
  (text "")                         ; edge label
  (style 'solid)                    ; solid | dotted | thick
  (arrow-start nil) (arrow-end t)
  (path nil)                        ; list of (x . y) grid coords
  (label-line nil)                  ; list of two grid coords
  (start-dir nil) (end-dir nil)     ; attachment directions used for drawing
  (segs nil) (seg-dirs nil)         ; draw-time: per-segment info
  (bundle nil)                      ; bm--bundle when bundled
  (path-to-junction nil))           ; grid coords for bundled edges

(cl-defstruct (bm--bundle (:constructor bm--bundle-create))
  type                              ; fan-in | fan-out
  edges                             ; list of bm--edge
  shared-node                       ; bm--node
  other-nodes                       ; list of bm--node
  (junction nil)                    ; (x . y) grid coord
  (shared-path nil))                ; list of grid coords

(cl-defstruct (bm--graph (:constructor bm--graph-create))
  direction                         ; LR | TD (normalized)
  flip-vertical                     ; t for BT
  (nodes nil)                       ; ordered list (insertion order)
  (lookup nil)                      ; hash table: id -> node
  (edges nil)                       ; list of bm--edge
  (grid nil)                        ; hash table: (x . y) -> node
  (col-w nil) (row-h nil)           ; hash tables: index -> size
  (canvas nil)                      ; hash table: (x . y) -> character
  (canvas-max-x -1) (canvas-max-y -1))

(defun bm--config ()
  "Current rendering config as a struct-less list of dynamic bindings."
  nil)

(defun bm--shape-frame (shape)
  "Frame chars for SHAPE: (TL TR BL BR H V).
Depends on `bm-char-profile' (and `bm-arrow-style' never applies here)."
  (let ((table (if (eq bm-char-profile 'full)
                   '((rectangle     ?┌ ?┐ ?└ ?┘ ?─ ?│)
                     (rounded       ?╭ ?╮ ?╰ ?╯ ?─ ?│)
                     (stadium       ?\( ?\) ?\( ?\) ?─ ?│)
                     (subroutine    ?╟ ?╢ ?╟ ?╢ ?─ ?│)
                     (cylinder      ?╭ ?╮ ?╰ ?╯ ?─ ?│)
                     (circle        ?◯ ?◯ ?◯ ?◯ ?─ ?│)
                     (doublecircle  ?◎ ?◎ ?◎ ?◎ ?─ ?│)
                     (hexagon       ?⌜ ?⌝ ?⌞ ?⌟ ?─ ?│)
                     (diamond       ?◇ ?◇ ?◇ ?◇ ?─ ?│)
                     (asymmetric    ?▷ ?┐ ?▷ ?┘ ?─ ?│)
                     (trapezoid     ?/ ?\\ ?└ ?┘ ?─ ?│)
                     (trapezoid-alt ?┌ ?┐ ?\\ ?/ ?─ ?│))
                 '((rectangle     ?┌ ?┐ ?└ ?┘ ?─ ?│)
                   (rounded       ?╔ ?╗ ?╚ ?╝ ?═ ?║)
                   (stadium       ?\( ?\) ?\( ?\) ?─ ?│)
                   (subroutine    ?╠ ?╣ ?╠ ?╣ ?─ ?│)
                   (cylinder      ?╔ ?╗ ?╚ ?╝ ?═ ?║)
                   (circle        ?◌ ?◌ ?◌ ?◌ ?─ ?│)
                   (doublecircle  ?◌ ?◌ ?◌ ?◌ ?─ ?│)
                   (hexagon       ?╱ ?╲ ?╲ ?╱ ?─ ?│)
                   (diamond       ?◊ ?◊ ?◊ ?◊ ?─ ?│)
                   (asymmetric    ?▷ ?┐ ?▷ ?┘ ?─ ?│)
                   (trapezoid     ?╱ ?╲ ?└ ?┘ ?─ ?│)
                   (trapezoid-alt ?┌ ?┐ ?╲ ?╱ ?─ ?│)))))
    (or (cdr (assq shape table))
        (cdr (assq 'rectangle table)))))

(defun bm--line-chars-for (style)
  "Horizontal and vertical line characters for STYLE, as (H . V)."
  (cl-case style
    (dotted (if (eq bm-char-profile 'full) '(?┄ . ?┆) '(?. . ?:)))
    (thick  (if (eq bm-char-profile 'full) '(?━ . ?┃) '(?═ . ?║)))
    (t '(?─ . ?│))))

(defun bm--corner-table ()
  "Corner characters per edge style for path bends: (RD RU LD LU).
Entries correspond to the four bend shapes; see `bm--corner-char'."
  (if (eq bm-char-profile 'full)
      '((solid  . (?┐ ?┘ ?┌ ?└))
        (dotted . (?┐ ?┘ ?┌ ?└))
        (thick  . (?┐ ?┘ ?┌ ?└)))
    '((solid  . (?┐ ?┘ ?┌ ?└))
      (dotted . (?┐ ?┘ ?┌ ?└))
      (thick  . (?╗ ?╝ ?╔ ?╚)))))

(defun bm--arrow-char (dir)
  "Arrowhead character for direction DIR (a bm-- direction constant).
Arrows always come from the safe character set: thin arrows by
default, solid triangles with `bm-arrow-style' set to `triangle'."
  (let ((table (if (eq bm-arrow-style 'triangle)
                   '((up . ?▲) (down . ?▼) (left . ?◀) (right . ?▶)
                     (upper-left . ?↖) (upper-right . ?↗)
                     (lower-left . ?↙) (lower-right . ?↘))
                 '((up . ?↑) (down . ?↓) (left . ?←) (right . ?→)
                   (upper-left . ?↖) (upper-right . ?↗)
                   (lower-left . ?↙) (lower-right . ?↘)))))
    (cdr (assq (bm--dir-name dir) table))))

(defun bm--dir-name (d)
  (cond ((equal d '(1 . 0)) 'up)
        ((equal d '(1 . 2)) 'down)
        ((equal d '(0 . 1)) 'left)
        ((equal d '(2 . 1)) 'right)
        ((equal d '(0 . 0)) 'upper-left)
        ((equal d '(2 . 0)) 'upper-right)
        ((equal d '(0 . 2)) 'lower-left)
        ((equal d '(2 . 2)) 'lower-right)
        (t 'middle)))

;; Direction constants: offsets into a node's 3x3 grid block.
(defconst bm--up          '(1 . 0))
(defconst bm--down        '(1 . 2))
(defconst bm--left        '(0 . 1))
(defconst bm--right       '(2 . 1))
(defconst bm--upper-right '(2 . 0))
(defconst bm--upper-left  '(0 . 0))
(defconst bm--lower-right '(2 . 2))
(defconst bm--lower-left  '(0 . 2))
(defconst bm--middle      '(1 . 1))

;; Unit movement vectors for A* pathfinding.  NOTE: distinct from the
;; block-relative direction constants above, which address attachment
;; points inside a node's 3x3 grid block (TS calls these MOVE_DIRS vs
;; Direction).
(defconst bm--move-dirs '((1 . 0) (-1 . 0) (0 . 1) (0 . -1)))

(defun bm--opposite-dir (d)
  (cond ((equal d bm--up) bm--down)
        ((equal d bm--down) bm--up)
        ((equal d bm--left) bm--right)
        ((equal d bm--right) bm--left)
        ((equal d bm--upper-right) bm--lower-left)
        ((equal d bm--upper-left) bm--lower-right)
        ((equal d bm--lower-right) bm--upper-left)
        ((equal d bm--lower-left) bm--upper-right)
        (t bm--middle)))

;; Characters that participate in junction merging (single-line set).
(defconst bm--junction-char-p-list '(?─ ?│ ?┌ ?┐ ?└ ?┘ ?├ ?┤ ?┬ ?┴ ?┼))
(defconst bm--double-line-chars '(?═ ?║ ?╔ ?╗ ?╚ ?╝ ?╠ ?╣ ?╦ ?╩ ?╬))

;; Junction merge semantics: each char connects a set of directions
;; (left=1 up=2 right=4 down=8); merging two chars unions their sets.
(defconst bm--junction-masks
  '((?─ . 5) (?│ . 10) (?┌ . 12) (?┐ . 9) (?└ . 6) (?┘ . 3)
    (?├ . 14) (?┤ . 11) (?┬ . 13) (?┴ . 7) (?┼ . 15)))

(defun bm--junction-p (ch) (memq ch bm--junction-char-p-list))

(defun bm--merge-junction (c1 c2)
  "Merge two overlapping junction characters (union of connections)."
  (let ((m1 (cdr (assq c1 bm--junction-masks)))
        (m2 (cdr (assq c2 bm--junction-masks))))
    (if (and m1 m2)
        (let ((mask (logior m1 m2)))
          (or (car (rassq mask bm--junction-masks)) c1))
      c1)))

;; Characters remapped when flipping the canvas vertically (BT direction).
(defconst bm--flip-map
  '((?▲ . ?▼) (?▼ . ?▲) (?↑ . ?↓) (?↓ . ?↑)
    (?↖ . ?↙) (?↙ . ?↖) (?↗ . ?↘) (?↘ . ?↗)
    (?┌ . ?└) (?└ . ?┌) (?┐ . ?┘) (?┘ . ?┐)
    (?╔ . ?╚) (?╚ . ?╔) (?╗ . ?╝) (?╝ . ?╗)
    (?┬ . ?┴) (?┴ . ?┬)))


;;; ================================ Parser =================================
;;
;; Regex line parser for `graph' / `flowchart' diagrams.  The TS parser
;; works line-by-line with anchored regexes; the Elisp port does the
;; same.  Emacs regex dialect notes: \\( \\) groups, \\| alternation,
;; \\(?: \\) shy group, \\` \\' string anchors, *? non-greedy.

(defconst bm--header-regexp
  "\\`\\(?:graph\\|flowchart\\)[ \t]+\\(TD\\|TB\\|LR\\|BT\\|RL\\)[ \t]*;?[ \t]*\\'")

(defconst bm--header-rest-regexp
  "\\`\\(?:graph\\|flowchart\\)[ \t]+\\(TD\\|TB\\|LR\\|BT\\|RL\\)[ \t]*;[ \t]*\\(.+\\)")

;; Lines to silently ignore (styles/subgraphs are out of scope but we
;; tolerate them so that shared sources still render).
(defconst bm--ignore-regexps
  '("\\`classDef[ \t]"
    "\\`class[ \t]+[[:alnum:]_.-]+[ \t]+[[:alnum:]_]+\\'"
    "\\`style[ \t]+[[:alnum:]_,-]+[ \t]+.+\\'"
    "\\`linkStyle[ \t]"
    "\\`direction[ \t]+\\(?:TD\\|TB\\|LR\\|BT\\|RL\\)[ \t]*\\'"
    "\\`subgraph[ \t]"
    "\\`end\\'")
  "Regexes for directives we parse-and-ignore (styles, subgraphs).")

;; Node shape patterns, most specific delimiter first (as in the TS
;; parser).  Each regexp captures the node ID (group 1) and label
;; (group 2).  Patterns are anchored with \\` and matched against the
;; remaining unconsumed text.
(defconst bm--node-shape-patterns
  '(("\\`\\([[:alnum:]_-]+\\)(((\\(.*?\\))))" . doublecircle)
    ("\\`\\([[:alnum:]_-]+\\)(\\[\\(.*?\\)\\])" . stadium)
    ("\\`\\([[:alnum:]_-]+\\)((\\(.*?\\)))" . circle)
    ("\\`\\([[:alnum:]_-]+\\)\\[\\[\\(.*?\\)\\]\\]" . subroutine)
    ("\\`\\([[:alnum:]_-]+\\)\\[(\\(.*?\\))\\]" . cylinder)
    ("\\`\\([[:alnum:]_-]+\\)\\[/\\(.*?\\)\\\\]" . trapezoid)
    ("\\`\\([[:alnum:]_-]+\\)\\[\\\\\\(.*?\\)/]" . trapezoid-alt)
    ("\\`\\([[:alnum:]_-]+\\)>\\(.*?\\)]" . asymmetric)
    ("\\`\\([[:alnum:]_-]+\\){{\\(.*?\\)}}" . hexagon)
    ("\\`\\([[:alnum:]_-]+\\)\\[\\(.*?\\)]" . rectangle)
    ("\\`\\([[:alnum:]_-]+\\)(\\(.*?\\))" . rounded)
    ("\\`\\([[:alnum:]_-]+\\){\\(.*?\\)}" . diamond)))

(defconst bm--bare-node-regexp "\\`\\([[:alnum:]_-]+\\)")
(defconst bm--class-shorthand-regexp "\\`:::[[:alnum:]][[:alnum:]_-]*")

;; Arrow operators with optional |label|: --> -.-> ==> --- -.- ===
(defconst bm--arrow-regexp
  "\\`\\(<\\)?\\(-->\\|-\\.->\\|==>\\|---\\|-\\.-\\|===\\)\\(?:|\\([^|]*\\)|\\)?")

;; Fallback: text-embedded label  -- label -->  -. label .->  == label ==>
(defconst bm--text-arrow-regexp
  "\\`\\(<\\)?\\(--\\|-\\.\\|==\\)[ \t]+\\(.*?\\)[ \t]+\\(-->\\|---\\|\\.->\\|-\\.-\\|==>\\|===\\)")

(defun bm--trim (s) (string-trim s))

(defun bm--normalize-label (s)
  "Normalize a label: strip quotes, <br> tags and formatting markup."
  (let ((s (if (and (>= (length s) 2)
                    (= (aref s 0) ?\")
                    (= (aref s (1- (length s))) ?\"))
               (substring s 1 -1)
             s))
        (case-fold-search t))
    (setq s (replace-regexp-in-string "<br[^>]*>" "\n" s t t))
    (setq s (replace-regexp-in-string "\\\\n" "\n" s t t))
    (setq s (replace-regexp-in-string
             "</?\\(?:b\\|strong\\|i\\|em\\|u\\|s\\|del\\|sub\\|sup\\|small\\|mark\\)[ \t]*>"
             "" s t t))
    s))

(defun bm--register-node (graph id label shape)
  "Register node ID with LABEL/SHAPE unless it already exists.
The first definition wins, as in the TS parser."
  (or (gethash id (bm--graph-lookup graph))
      (let ((node (bm--node-create :id id :label label :shape shape)))
        (puthash id node (bm--graph-lookup graph))
        (push node (bm--graph-nodes graph))
        node)))

(defun bm--consume-node (graph s)
  "Consume one node at the start of S.
Return (ID . REMAINING), or nil when S does not start with a node."
  (let (id remaining matched)
    (dolist (pat bm--node-shape-patterns)
      (unless matched
        (when (string-match (car pat) s)
          (setq matched t
                id (match-string 1 s)
                remaining (substring s (match-end 0)))
          (bm--register-node graph id
                             (bm--normalize-label (match-string 2 s))
                             (cdr pat)))))
    (unless matched
      (when (string-match bm--bare-node-regexp s)
        (setq id (match-string 1 s)
              remaining (substring s (match-end 0)))
        (bm--register-node graph id id 'rectangle)))
    (when id
      ;; consume-and-drop :::class shorthand
      (when (string-match bm--class-shorthand-regexp remaining)
        (setq remaining (substring remaining (match-end 0))))
      (cons id remaining))))

(defun bm--consume-node-group (graph s)
  "Consume one or more nodes separated by &, as in `A & B --> ...'.
Return (IDS . REMAINING), or nil."
  (let ((first (bm--consume-node graph s)))
    (when first
      (let ((ids (list (car first)))
            (rest (bm--trim (cdr first))))
        (catch 'bm--break
          (while (string-prefix-p "&" rest)
            (setq rest (bm--trim (substring rest 1)))
            (let ((next (bm--consume-node graph rest)))
              (unless next (throw 'bm--break nil))
              (push (car next) ids)
              (setq rest (bm--trim (cdr next))))))
        (cons (nreverse ids) rest)))))

(defun bm--arrow-style-from-op (op)
  (cond ((equal op "-.->") 'dotted)
        ((equal op "-.-") 'dotted)
        ((equal op "==>") 'thick)
        ((equal op "===") 'thick)
        (t 'solid)))

(defun bm--text-arrow-style (open close)
  (cond ((or (equal open "-.") (equal close ".->") (equal close "-.-"))
         'dotted)
        ((or (equal open "==") (equal close "==>") (equal close "==="))
         'thick)
        (t 'solid)))

(defun bm--match-arrow (s)
  "Match an arrow operator at the start of S.
Return (HAS-START STYLE HAS-END LABEL . REMAINING), or nil."
  (when (string-match bm--arrow-regexp s)
    (let* ((has-start (and (match-beginning 1) t))
           (op (match-string 2 s))
           (raw-label (match-string 3 s))
           (label (and raw-label
                       (> (length (bm--trim raw-label)) 0)
                       (bm--normalize-label (bm--trim raw-label))))
           (rest (substring s (match-end 0))))
      (list has-start
            (bm--arrow-style-from-op op)
            (and (string-match-p ">$" op) t)
            (or label "")
            rest))))

(defun bm--match-text-arrow (s)
  "Match `-- label -->' style arrow at the start of S."
  (when (string-match bm--text-arrow-regexp s)
    (let* ((has-start (and (match-beginning 1) t))
           (open (match-string 2 s))
           (raw-label (match-string 3 s))
           (close (match-string 4 s))
           (label (and (> (length (bm--trim raw-label)) 0)
                       (bm--normalize-label (bm--trim raw-label))))
           (rest (substring s (match-end 0))))
      (list has-start
            (bm--text-arrow-style open close)
            (and (string-match-p ">$" close) t)
            (or label "")
            rest))))

(defun bm--ignored-line-p (s)
  (let (found)
    (dolist (re bm--ignore-regexps found)
      (unless found
        (when (string-match re s) (setq found t))))))

(defun bm--parse-edge-line (graph line)
  "Parse one line of node definitions and edges."
  (let ((s (bm--trim line)))
    (unless (or (zerop (length s)) (bm--ignored-line-p s))
      (let ((group (bm--consume-node-group graph s)))
        (when group
          (let ((prev-ids (car group))
                (remaining (bm--trim (cdr group)))
                (done nil))
            (while (and (not done) (> (length remaining) 0))
              (let ((arrow (or (bm--match-arrow remaining)
                               (bm--match-text-arrow remaining))))
                (if (null arrow)
                    (setq done t)
                  (let ((group2 (bm--consume-node-group
                                 graph (bm--trim (nth 4 arrow)))))
                    (if (or (null group2) (null (car group2)))
                        (setq done t)
                      (dolist (src prev-ids)
                        (dolist (dst (car group2))
                          (push (bm--edge-create
                                 :from (gethash src (bm--graph-lookup graph))
                                 :to (gethash dst (bm--graph-lookup graph))
                                 :text (nth 3 arrow)
                                 :style (nth 1 arrow)
                                 :arrow-start (nth 0 arrow)
                                 :arrow-end (nth 2 arrow))
                                (bm--graph-edges graph))))
                      (setq prev-ids (car group2))
                      (setq remaining (bm--trim (cdr group2))))))))))))))

(defun bm--parse (text)
  "Parse mermaid flowchart TEXT into a bm--graph."
  (let* ((raw-lines (split-string text "\n"))
         (lines (delq nil
                      (mapcar (lambda (l)
                                (let ((l (bm--trim l)))
                                  (if (or (zerop (length l))
                                          (string-prefix-p "%%" l))
                                      nil l)))
                              raw-lines))))
    (when (null lines)
      (error "Empty mermaid diagram"))
    (let ((header (car lines))
          (case-fold-search t)
          direction rest-line)
      (cond ((string-match bm--header-regexp header)
             (setq direction (upcase (match-string 1 header))))
            ((string-match bm--header-rest-regexp header)
             (setq direction (upcase (match-string 1 header))
                   rest-line (match-string 2 header)))
            (t (error
                "Invalid mermaid header: %s (expected \"graph TD\", \"flowchart LR\", etc.)"
                header)))
      (let* ((norm (cond ((member direction '("TD" "TB" "BT")) 'TD)
                         (t 'LR)))
             (graph (bm--graph-create
                     :direction norm
                     :flip-vertical (equal direction "BT")
                     :lookup (make-hash-table :test #'equal)
                     :grid (make-hash-table :test #'equal)
                     :col-w (make-hash-table)
                     :row-h (make-hash-table)
                     :canvas (make-hash-table :test #'equal))))
        (when rest-line
          (bm--parse-edge-line graph rest-line))
        (dolist (line (cdr lines))
          (bm--parse-edge-line graph line))
        (setf (bm--graph-nodes graph) (nreverse (bm--graph-nodes graph)))
        (setf (bm--graph-edges graph) (nreverse (bm--graph-edges graph)))
        graph))))

(defun bm--children (graph node)
  "Targets of edges leaving NODE, in edge order."
  (delq nil
        (mapcar (lambda (e)
                  (when (eq (bm--edge-from e) node) (bm--edge-to e)))
                (bm--graph-edges graph))))


;;; ============================= Grid layout ===============================

(defun bm--reserve (graph node coord)
  "Reserve a 3x3 grid block for NODE at COORD, shifting on collision."
  (let* ((lr-p (eq (bm--graph-direction graph) 'LR))
         (x (car coord)) (y (cdr coord))
         (grid (bm--graph-grid graph)))
    (if (gethash (cons x y) grid)
        (bm--reserve graph node
                     (if lr-p (cons x (+ y 4)) (cons (+ x 4) y)))
      (let ((node (or (gethash (cons x y) grid) node)))
        (dotimes (dx 3)
          (dotimes (dy 3)
            (puthash (cons (+ x dx) (+ y dy)) node grid)))
        (setf (bm--node-gx node) x)
        (setf (bm--node-gy node) y)))))

(defun bm--shape-grid-dims (shape label)
  "Grid column/row sizes for a node of SHAPE with LABEL: (COLS . ROWS).
Most shapes use [1,innerW,1] / [1,innerH,1].  Exceptions (matching
the TS renderers' getDimensions): subroutine and stadium get 2-wide
border columns for their double-bar/parenthesis corners; cylinder
gets 2-wide border rows for its curved top/bottom."
  (let* ((lines (split-string label "\n"))
         (n (length lines))
         (maxw 0))
    (dolist (l lines) (setq maxw (max maxw (string-width l))))
    (let* ((inner-w (+ (* 2 bm-box-padding) maxw))
           (raw-h (+ n (* 2 bm-box-padding)))
           (inner-h (if (zerop (% raw-h 2)) (1+ raw-h) raw-h)))
      (cond
       ((memq shape '(subroutine stadium))
        (cons (list 2 inner-w 2) (list 1 inner-h 1)))
       ((eq shape 'cylinder)
        (cons (list 1 inner-w 1)
              (list 2 (+ n (* 2 bm-box-padding)) 2)))
       (t
        (cons (list 1 inner-w 1) (list 1 inner-h 1)))))))

(defun bm--set-col-width (graph node)
  "Size the grid columns/rows occupied by NODE from its label."
  (let* ((gcx (bm--node-gx node))
         (gcy (bm--node-gy node))
         (dims (bm--shape-grid-dims (bm--node-shape node)
                                    (bm--node-label node)))
         (cols (car dims))
         (rows (cdr dims))
         (col-w (bm--graph-col-w graph))
         (row-h (bm--graph-row-h graph)))
    (dotimes (i 3)
      (let ((kx (+ gcx i)) (ky (+ gcy i)))
        (puthash kx (max (gethash kx col-w 0) (nth i cols)) col-w)
        (puthash ky (max (gethash ky row-h 0) (nth i rows)) row-h)))
    (when (> gcx 0)
      (let ((k (1- gcx)))
        (puthash k (max (gethash k col-w 0) bm-padding-x) col-w)))
    (when (> gcy 0)
      (let ((k (1- gcy)))
        (puthash k (max (gethash k row-h 0) bm-padding-y) row-h)))))

(defun bm--sum-below (table n)
  "Sum entries 0..N-1 of TABLE (a hash table of integer sizes)."
  (let ((total 0) (i 0))
    (while (< i n)
      (cl-incf total (gethash i table 0))
      (cl-incf i))
    total))

(defun bm--grid->drawing (graph x y &optional dir)
  "Convert grid coordinate (X Y) to a character cell center.
DIR optionally shifts into a node's 3x3 block first (attachment point)."
  (when dir
    (cl-incf x (car dir))
    (cl-incf y (cdr dir)))
  (let* ((col-w (bm--graph-col-w graph))
         (row-h (bm--graph-row-h graph))
         (cx (bm--sum-below col-w x))
         (cy (bm--sum-below row-h y)))
    (cons (+ cx (floor (gethash x col-w 0) 2))
          (+ cy (floor (gethash y row-h 0) 2)))))

(defun bm--increase-grid-for-path (graph path)
  "Ensure grid cells along PATH have column widths and row heights."
  (let ((col-w (bm--graph-col-w graph))
        (row-h (bm--graph-row-h graph)))
    (dolist (c path)
      (unless (gethash (car c) col-w)
        (puthash (car c) (floor bm-padding-x 2) col-w))
      (unless (gethash (cdr c) row-h)
        (puthash (cdr c) (floor bm-padding-y 2) row-h)))))

;; ---- A* pathfinding ------------------------------------------------------

(defun bm--heap-create ()
  "Create a binary min-heap.  Return (PUSH . POP) closures."
  (let* ((v (make-vector 1024 nil))
         (count 0)
         (grow (lambda ()
                 (let ((new (make-vector (* 2 (length v)) nil)))
                   (dotimes (i (length v)) (aset new i (aref v i)))
                   (setq v new)))))
    (cons
     (lambda (prio item)
       (when (= count (1- (length v))) (funcall grow))
       (cl-incf count)
       (aset v count (cons prio item))
       (let ((i count))
         (while (> i 1)
           (let ((parent (ash i -1)))
             (if (< (car (aref v i)) (car (aref v parent)))
                 (let ((tmp (aref v i)))
                   (aset v i (aref v parent))
                   (aset v parent tmp)
                   (setq i parent))
               (setq i 1))))))
     (lambda ()
       (if (zerop count)
           nil
         (let ((top (aref v 1)) (i 1) (done nil))
           (aset v 1 (aref v count))
           (aset v count nil)
           (cl-decf count)
           (while (not done)
             (let* ((l (* 2 i)) (r (1+ l)) (smallest i))
               (when (<= l count)
                 (when (< (car (aref v l)) (car (aref v smallest)))
                   (setq smallest l)))
               (when (<= r count)
                 (when (< (car (aref v r)) (car (aref v smallest)))
                   (setq smallest r)))
               (if (= smallest i)
                   (setq done t)
                 (let ((tmp (aref v i)))
                   (aset v i (aref v smallest))
                   (aset v smallest tmp)
                   (setq i smallest)))))
           top))))))

(defun bm--heuristic (a b)
  "Manhattan distance with +1 corner penalty (prefers straight lines)."
  (let ((dx (abs (- (car a) (car b))))
        (dy (abs (- (cdr a) (cdr b)))))
    (if (or (zerop dx) (zerop dy))
        (+ dx dy)
      (1+ (+ dx dy)))))

(defun bm--astar (grid from to)
  "A* path between FROM and TO over GRID (hash of occupied cells).
Returns a list of (x . y) cells, or nil."
  (let* ((heap (bm--heap-create))
         (push (car heap))
         (pop (cdr heap))
         (cost (make-hash-table :test #'equal))
         (came (make-hash-table :test #'equal)))
    (puthash from 0 cost)
    (funcall push 0 from)
    (catch 'bm--done
      (while t
        (let ((item (funcall pop)))
          (unless item (throw 'bm--done nil))
          (let* ((cur (cdr item))
                 (cur-cost (gethash cur cost)))
            (when (equal cur to)
              ;; reconstruct
              (let ((path (list cur)) (c cur))
                (while (and (setq c (gethash c came)) (not (equal c from)))
                  (push c path))
                (push from path)
                (throw 'bm--done path)))
            (dolist (d bm--move-dirs)
              (let* ((nx (+ (car cur) (car d)))
                     (ny (+ (cdr cur) (cdr d)))
                     (nkey (cons nx ny)))
                (when (and (>= nx 0) (>= ny 0)
                           (or (not (gethash nkey grid))
                               (equal nkey to)))
                  (let ((new-cost (1+ cur-cost)))
                    (when (or (not (gethash nkey cost))
                              (< new-cost (gethash nkey cost)))
                      (puthash nkey new-cost cost)
                      (puthash nkey cur came)
                      (funcall push (+ new-cost (bm--heuristic nkey to))
                               nkey))))))))))))

(defun bm--merge-path (path)
  "Drop collinear intermediate waypoints from PATH."
  (if (<= (length path) 2)
      path
    (let ((remove (make-hash-table))
          (i 2)
          (s0 (nth 0 path))
          (s1 (nth 1 path)))
      (while (< i (length path))
        (let ((s2 (nth i path)))
          (when (and (= (- (car s1) (car s0)) (- (car s2) (car s1)))
                     (= (- (cdr s1) (cdr s0)) (- (cdr s2) (cdr s1))))
            (puthash (1- i) t remove))
          (setq s0 s1 s1 s2 i (1+ i))))
      (let ((result nil) (idx 0))
        (dolist (p path)
          (unless (gethash idx remove) (push p result))
          (cl-incf idx))
        (nreverse result)))))

;; ---- Edge routing --------------------------------------------------------

(defun bm--determine-direction (from to)
  "8-way direction between two coordinates (grid or drawing coords)."
  (cond ((= (car from) (car to))
         (if (< (cdr from) (cdr to)) bm--down bm--up))
        ((= (cdr from) (cdr to))
         (if (< (car from) (car to)) bm--right bm--left))
        ((< (car from) (car to))
         (if (< (cdr from) (cdr to)) bm--lower-right bm--upper-right))
        (t (if (< (cdr from) (cdr to)) bm--lower-left bm--upper-left))))

(defun bm--start-and-end-dirs (edge lr-p)
  "Attachment directions to try for EDGE.
Return (PREF-START PREF-END ALT-START ALT-END)."
  (let ((from (bm--edge-from edge))
        (to (bm--edge-to edge)))
    (if (eq from to)
        (if lr-p
            (list bm--right bm--down bm--down bm--right)
          (list bm--down bm--right bm--right bm--down))
      (let* ((d (bm--determine-direction
                 (cons (bm--node-gx from) (bm--node-gy from))
                 (cons (bm--node-gx to) (bm--node-gy to))))
             (opp (bm--opposite-dir d)))
        (cond
         ((equal d bm--lower-right)
          (if lr-p
              (list bm--down bm--left bm--right bm--up)
            (list bm--right bm--up bm--down bm--left)))
         ((equal d bm--upper-right)
          (if lr-p
              (list bm--up bm--left bm--right bm--down)
            (list bm--right bm--down bm--up bm--left)))
         ((equal d bm--lower-left)
          (if lr-p
              (list bm--down bm--down bm--left bm--up)
            (list bm--left bm--up bm--down bm--right)))
         ((equal d bm--upper-left)
          (if lr-p
              (list bm--down bm--down bm--left bm--down)
            (list bm--right bm--right bm--up bm--right)))
         ((and lr-p (equal d bm--left))
          (list bm--down bm--down bm--left bm--right))
         ((and (not lr-p) (equal d bm--up))
          (list bm--right bm--right bm--up bm--down))
         (t (list d opp d opp)))))))

(defun bm--gc+dir (gc dir)
  (cons (+ (car gc) (car dir)) (+ (cdr gc) (cdr dir))))

(defun bm--determine-path (graph edge)
  "Route EDGE with A*, trying preferred then alternative attachments."
  (let* ((lr-p (eq (bm--graph-direction graph) 'LR))
         (dirs (bm--start-and-end-dirs edge lr-p))
         (ps (nth 0 dirs)) (pe (nth 1 dirs))
         (as (nth 2 dirs)) (ae (nth 3 dirs))
         (from (bm--edge-from edge)) (to (bm--edge-to edge))
         (fgc (cons (bm--node-gx from) (bm--node-gy from)))
         (tgc (cons (bm--node-gx to) (bm--node-gy to)))
         (grid (bm--graph-grid graph))
         (pf (bm--gc+dir fgc ps)) (pt (bm--gc+dir tgc pe))
         (p-path (bm--astar grid pf pt))
         (af (bm--gc+dir fgc as)) (at (bm--gc+dir tgc ae))
         (a-path (bm--astar grid af at)))
    (cond
     ((and p-path a-path)
      (let ((mp (bm--merge-path p-path))
            (ma (bm--merge-path a-path)))
        (if (<= (length mp) (length ma))
            (setf (bm--edge-path edge) mp)
          (setf (bm--edge-path edge) ma))))
     (p-path (setf (bm--edge-path edge) (bm--merge-path p-path)))
     (a-path (setf (bm--edge-path edge) (bm--merge-path a-path)))
     (t (setf (bm--edge-path edge) (list pf pt))))))

(defun bm--line-width (graph p1 p2)
  "Character width of the grid segment P1 -> P2."
  (let ((total 0)
        (x (min (car p1) (car p2)))
        (end (max (car p1) (car p2))))
    (while (<= x end)
      (cl-incf total (gethash x (bm--graph-col-w graph) 0))
      (cl-incf x))
    total))

(defun bm--determine-label-line (graph edge)
  "Pick the path segment on which to center EDGE's label."
  (let ((text (bm--edge-text edge)))
    (when (> (length text) 0)
      (let* ((len (string-width text))
             (path (bm--edge-path edge))
             (segments nil)
             (i 1))
        (while (< i (length path))
          (let ((p1 (nth (1- i) path)) (p2 (nth i path)))
            (push (list (bm--line-width graph p1 p2) i p1 p2) segments))
          (cl-incf i))
        (setq segments (nreverse segments))
        (when segments
          (let* ((pick
                  (let ((suitable nil) (fallback nil))
                    (dolist (s segments)
                      (when (>= (nth 0 s) len)
                        (if (> (nth 1 s) 1)
                            (push s suitable)
                          (push s fallback))))
                    (cond (suitable (car suitable))   ; highest index wins
                          (fallback (car fallback))
                          (t (let ((best nil))
                               (dolist (s segments)
                                 (when (or (null best)
                                           (> (nth 0 s) (nth 0 best)))
                                   (setq best s)))
                               best)))))
                 (p1 (nth 2 pick)) (p2 (nth 3 pick))
                 (minx (min (car p1) (car p2)))
                 (maxx (max (car p1) (car p2)))
                 (mx (+ minx (floor (- maxx minx) 2)))
                 (col-w (bm--graph-col-w graph)))
            (puthash mx (max (gethash mx col-w 0) (+ len 2)) col-w)
            (setf (bm--edge-label-line edge) (list p1 p2))))))))

;; ---- Edge bundling (parallel links) --------------------------------------

(defun bm--can-bundle (edges)
  "t when EDGES can share a junction: same style, no labels.
(Self-loops are excluded before grouping; without subgraphs the
subgraph-boundary checks of the TS version always pass.)"
  (and (>= (length edges) 2)
       (let ((style (bm--edge-style (car edges)))
             (ok t))
         (dolist (e edges ok)
           (when (or (not (eq (bm--edge-style e) style))
                     (> (length (bm--edge-text e)) 0))
             (setq ok nil))))))

(defun bm--analyze-bundles (graph)
  "Group fan-in/fan-out edges into bundles.  TD only — LR routing
merges naturally at corners (as in the TS renderer)."
  (when (eq (bm--graph-direction graph) 'TD)
    (let ((bundled (make-hash-table :test #'eq))
          (bundles nil))
      ;; fan-in: group edges sharing a target
      (let ((by-target nil))
        (dolist (edge (bm--graph-edges graph))
          (unless (eq (bm--edge-from edge) (bm--edge-to edge))
            (let ((entry (assq (bm--edge-to edge) by-target)))
              (if entry
                  (setcdr entry (append (cdr entry) (list edge)))
                (push (cons (bm--edge-to edge) (list edge)) by-target)))))
        (dolist (group by-target)
          (let* ((edges (cdr group)))
            (when (and (>= (length edges) 2)
                       (bm--can-bundle edges)
                       (not (cl-some (lambda (e) (gethash e bundled)) edges)))
              (let ((bundle (bm--bundle-create
                             :type 'fan-in
                             :edges edges
                             :shared-node (car group)
                             :other-nodes (mapcar #'bm--edge-from edges))))
                (dolist (e edges)
                  (setf (bm--edge-bundle e) bundle)
                  (puthash e t bundled))
                (push bundle bundles))))))
      ;; fan-out: group remaining edges sharing a source
      (let ((by-source nil))
        (dolist (edge (bm--graph-edges graph))
          (unless (or (eq (bm--edge-from edge) (bm--edge-to edge))
                      (gethash edge bundled))
            (let ((entry (assq (bm--edge-from edge) by-source)))
              (if entry
                  (setcdr entry (append (cdr entry) (list edge)))
                (push (cons (bm--edge-from edge) (list edge)) by-source)))))
        (dolist (group by-source)
          (let* ((edges (cdr group)))
            (when (and (>= (length edges) 2)
                       (bm--can-bundle edges))
              (let ((bundle (bm--bundle-create
                             :type 'fan-out
                             :edges edges
                             :shared-node (car group)
                             :other-nodes (mapcar #'bm--edge-to edges))))
                (dolist (e edges)
                  (setf (bm--edge-bundle e) bundle)
                  (puthash e t bundled))
                (push bundle bundles))))))
      (nreverse bundles))))

(defun bm--process-bundles (graph bundles)
  "Calculate junction points and route all bundled edges."
  (dolist (bundle bundles)
    (let* ((shared (bm--bundle-shared-node bundle))
           (sgx (bm--node-gx shared)) (sgy (bm--node-gy shared))
           (junction (if (eq (bm--bundle-type bundle) 'fan-in)
                         (cons (+ sgx 1) (1- sgy))     ; above target
                       (cons (+ sgx 1) (+ sgy 3)))))   ; below source
      (setf (bm--bundle-junction bundle) junction)
      (if (eq (bm--bundle-type bundle) 'fan-in)
          ;; junction -> target (shared), each source -> junction
          (let* ((target-entry (cons (+ sgx 1) sgy))
                 (sp (bm--astar (bm--graph-grid graph) junction target-entry)))
            (setf (bm--bundle-shared-path bundle)
                  (if sp (bm--merge-path sp) (list junction target-entry)))
            (dolist (edge (bm--bundle-edges bundle))
              (let* ((src (bm--edge-from edge))
                     (exit (cons (+ (bm--node-gx src) 1)
                                 (+ (bm--node-gy src) 2)))
                     (p (bm--astar (bm--graph-grid graph) exit junction)))
                (setf (bm--edge-path-to-junction edge)
                      (if p (bm--merge-path p) (list exit junction)))
                (setf (bm--edge-start-dir edge) bm--down)
                (setf (bm--edge-end-dir edge) bm--up)
                (setf (bm--edge-path edge)
                      (append (bm--edge-path-to-junction edge)
                              (cdr (bm--bundle-shared-path bundle)))))))
        ;; source -> junction (shared), junction -> each target
        (let* ((source-exit (cons (+ sgx 1) (+ sgy 2)))
               (sp (bm--astar (bm--graph-grid graph) source-exit junction)))
          (setf (bm--bundle-shared-path bundle)
                (if sp (bm--merge-path sp) (list source-exit junction)))
          (dolist (edge (bm--bundle-edges bundle))
            (let* ((tgt (bm--edge-to edge))
                   (entry (cons (+ (bm--node-gx tgt) 1)
                                (bm--node-gy tgt)))
                   (p (bm--astar (bm--graph-grid graph) junction entry)))
              (setf (bm--edge-path-to-junction edge)
                    (if p (bm--merge-path p) (list junction entry)))
              (setf (bm--edge-start-dir edge) bm--down)
              (setf (bm--edge-end-dir edge) bm--up)
              (setf (bm--edge-path edge)
                    (append (bm--bundle-shared-path bundle)
                            (cdr (bm--edge-path-to-junction edge)))))))))))

;; ---- Layout orchestrator -------------------------------------------------

(defun bm--layout (graph)
  "Place nodes on the grid, size cells, route all edges."
  (let* ((lr-p (eq (bm--graph-direction graph) 'LR))
         (hppl (make-hash-table))     ; level -> next free position
         (seen (make-hash-table :test #'equal))
         (roots nil))
    ;; Roots: first appearance in document order that is not already
    ;; known as somebody's child.
    (dolist (node (bm--graph-nodes graph))
      (unless (gethash (bm--node-id node) seen)
        (push node roots))
      (puthash (bm--node-id node) t seen)
      (dolist (child (bm--children graph node))
        (puthash (bm--node-id child) t seen)))
    (setq roots (nreverse roots))
    ;; Place roots at level 0, 4 grid units apart.
    (dolist (node roots)
      (let ((p (gethash 0 hppl 0)))
        (bm--reserve graph node (if lr-p (cons 0 p) (cons p 0)))
        (puthash 0 (+ p 4) hppl)))
    ;; Place children level by level (multi-pass for arbitrary order).
    (let ((placed (length roots))
          (total (length (bm--graph-nodes graph)))
          (progress t))
      (while (and (< placed total) progress)
        (setq progress nil)
        (dolist (node (bm--graph-nodes graph))
          (when (bm--node-gx node)
            (dolist (child (bm--children graph node))
              (unless (bm--node-gx child)
                (let* ((level (if lr-p
                                  (+ (bm--node-gx node) 4)
                                (+ (bm--node-gy node) 4)))
                       (highest (gethash level hppl 0)))
                  (bm--reserve graph child
                               (if lr-p (cons level highest)
                                 (cons highest level)))
                  (puthash level (+ highest 4) hppl)
                  (cl-incf placed)
                  (setq progress t))))))))
    ;; Cell sizes from node labels.
    (dolist (node (bm--graph-nodes graph))
      (bm--set-col-width graph node))
    ;; Bundle parallel links (fan-in/fan-out) and route through junctions.
    (bm--process-bundles graph (bm--analyze-bundles graph))
    ;; Route remaining edges and place labels (order matters: label
    ;; placement widens columns, which must happen before drawing
    ;; coords are computed).
    (dolist (edge (bm--graph-edges graph))
      (unless (and (bm--edge-bundle edge) (bm--edge-path edge))
        (bm--determine-path graph edge))
      (bm--increase-grid-for-path graph (bm--edge-path edge))
      (bm--determine-label-line graph edge))
    ;; Grid -> drawing coordinates.
    (dolist (node (bm--graph-nodes graph))
      (let ((dc (bm--grid->drawing graph (bm--node-gx node)
                                   (bm--node-gy node))))
        (setf (bm--node-dx node) (car dc))
        (setf (bm--node-dy node) (cdr dc))))))


;;; ================================ Drawing ================================

(defun bm--canvas-put (graph x y ch)
  "Set cell (X, Y) to CH with TS merge semantics.
Junction chars merge; label characters never overwrite each other."
  (let* ((canvas (bm--graph-canvas graph))
         (key (cons x y))
         (cur (gethash key canvas)))
    (cond
     ((and cur (memq cur bm--double-line-chars)
           (memq ch bm--double-line-chars)
           (memq ch '(?═ ?║)))
      ;; crossing thick lines merge into ╬
      (puthash key (if (eq cur ch) cur ?╬) canvas))
     ((and cur (bm--junction-p cur) (bm--junction-p ch))
      (puthash key (bm--merge-junction cur ch) canvas))
     ((and cur (bm--alnum-p cur) (bm--alnum-p ch))
      ;; labels never overwrite labels (first wins)
      nil)
     (t (puthash key ch canvas)))
    (when (> x (bm--graph-canvas-max-x graph))
      (setf (bm--graph-canvas-max-x graph) x))
    (when (> y (bm--graph-canvas-max-y graph))
      (setf (bm--graph-canvas-max-y graph) y))))

(defun bm--alnum-p (ch)
  (or (and (>= ch ?a) (<= ch ?z))
      (and (>= ch ?A) (<= ch ?Z))
      (and (>= ch ?0) (<= ch ?9))))

(defconst bm--wide-marker 'bm--wide
  "Marker stored in canvas cells absorbed by a wide (2-column) glyph.")

(defun bm--draw-string (graph x y s)
  "Draw string S at (X, Y), advancing by display width per character.
Wide characters (CJK etc.) absorb the canvas cells they cover, so the
serialized string renders them contiguously and box borders align."
  (let ((i 0))
    (dolist (ch (string-to-list s))
      (bm--canvas-put graph (+ x i) y ch)
      (let ((w (string-width (string ch))))
        (when (> w 1)
          (let ((k (1+ i)))
            (while (< k (+ i w))
              (puthash (cons (+ x k) y) bm--wide-marker
                       (bm--graph-canvas graph))
              (cl-incf k))))
        (cl-incf i w)))))

(defun bm--draw-node-box (graph node)
  "Draw NODE's box: border, corners, centered (multi-line) label."
  (let* ((gcx (bm--node-gx node)) (gcy (bm--node-gy node))
         (dx (bm--node-dx node)) (dy (bm--node-dy node))
         (w (+ (gethash gcx (bm--graph-col-w graph) 0)
               (gethash (1+ gcx) (bm--graph-col-w graph) 0)))
         (h (+ (gethash gcy (bm--graph-row-h graph) 0)
               (gethash (1+ gcy) (bm--graph-row-h graph) 0)))
         (frame (bm--shape-frame (bm--node-shape node)))
         (tl (nth 0 frame)) (tr (nth 1 frame))
         (bl (nth 2 frame)) (br (nth 3 frame))
         (hch (nth 4 frame)) (vch (nth 5 frame)))
    (cl-loop for x from (1+ dx) below (+ dx w)
             do (bm--canvas-put graph x dy hch)
             do (bm--canvas-put graph x (+ dy h) hch))
    (cl-loop for y from (1+ dy) below (+ dy h)
             do (bm--canvas-put graph dx y vch)
             do (bm--canvas-put graph (+ dx w) y vch))
    (bm--canvas-put graph dx dy tl)
    (bm--canvas-put graph (+ dx w) dy tr)
    (bm--canvas-put graph dx (+ dy h) bl)
    (bm--canvas-put graph (+ dx w) (+ dy h) br)
    (let* ((lines (split-string (bm--node-label node) "\n"))
           (n (length lines))
           (start-y (+ dy (- (floor h 2) (floor (1- n) 2)))))
      (cl-loop for line in lines
               for i from 0
               do (let ((tx (+ 1 dx (- (floor w 2)
                                       (ceiling (string-width line) 2)))))
                    (bm--draw-string graph tx (+ start-y i) line))))))

(defun bm--draw-line (graph from to of ot style)
  "Draw an orthogonal line between drawing coords FROM and TO.
OF/OT skip that many cells at the start/end (1 and -1 for edges).
Return the list of cells drawn."
  (let* ((dir (bm--determine-direction from to))
         (chars (bm--line-chars-for style))
         (hch (car chars)) (vch (cdr chars))
         (fx (car from)) (fy (cdr from))
         (tx (car to)) (ty (cdr to))
         (drawn nil))
    (cond
     ((equal dir bm--up)
      (let ((y (- fy of)))
        (while (>= y (- ty ot))
          (bm--canvas-put graph fx y vch)
          (push (cons fx y) drawn)
          (cl-decf y))))
     ((equal dir bm--down)
      (let ((y (+ fy of)))
        (while (<= y (+ ty ot))
          (bm--canvas-put graph fx y vch)
          (push (cons fx y) drawn)
          (cl-incf y))))
     ((equal dir bm--left)
      (let ((x (- fx of)))
        (while (>= x (- tx ot))
          (bm--canvas-put graph x fy hch)
          (push (cons x fy) drawn)
          (cl-decf x))))
     ((equal dir bm--right)
      (let ((x (+ fx of)))
        (while (<= x (+ tx ot))
          (bm--canvas-put graph x fy hch)
          (push (cons x fy) drawn)
          (cl-incf x))))
     ((equal dir bm--upper-left)
      (let ((x (- fx of)))
        (while (>= x tx)
          (bm--canvas-put graph x fy hch)
          (push (cons x fy) drawn)
          (cl-decf x)))
      (let ((y (- fy 1)))
        (while (>= y (- ty ot))
          (bm--canvas-put graph tx y vch)
          (push (cons tx y) drawn)
          (cl-decf y))))
     ((equal dir bm--upper-right)
      (let ((x (+ fx of)))
        (while (<= x tx)
          (bm--canvas-put graph x fy hch)
          (push (cons x fy) drawn)
          (cl-incf x)))
      (let ((y (- fy 1)))
        (while (>= y (- ty ot))
          (bm--canvas-put graph tx y vch)
          (push (cons tx y) drawn)
          (cl-decf y))))
     ((equal dir bm--lower-left)
      (let ((x (- fx of)))
        (while (>= x tx)
          (bm--canvas-put graph x fy hch)
          (push (cons x fy) drawn)
          (cl-decf x)))
      (let ((y (+ fy 1)))
        (while (<= y (+ ty ot))
          (bm--canvas-put graph tx y vch)
          (push (cons tx y) drawn)
          (cl-incf y))))
     ((equal dir bm--lower-right)
      (if (<= (- tx fx) 1)
          (let ((y (+ fy of)))
            (while (<= y (+ ty ot))
              (bm--canvas-put graph fx y vch)
              (push (cons fx y) drawn)
              (cl-incf y)))
        (let ((x (+ fx of)))
          (while (<= x tx)
            (bm--canvas-put graph x fy hch)
            (push (cons x fy) drawn)
            (cl-incf x)))
        (let ((y (+ fy 1)))
          (while (<= y (+ ty ot))
            (bm--canvas-put graph tx y vch)
            (push (cons tx y) drawn)
            (cl-incf y))))))
    (nreverse drawn)))

(defun bm--draw-edge-lines (graph edge)
  "Draw EDGE's path segments; record per-segment cells and directions."
  (let* ((path (bm--edge-path edge))
         (segs nil)
         (dirs nil)
         (prev (car path)))
    (dolist (next (cdr path))
      (let ((pdc (bm--grid->drawing graph (car prev) (cdr prev)))
            (ndc (bm--grid->drawing graph (car next) (cdr next))))
        (unless (equal pdc ndc)
          (let* ((dir (bm--determine-direction prev next))
                 (seg (bm--draw-line graph pdc ndc 1 -1
                                     (bm--edge-style edge))))
            (when (null seg) (setq seg (list pdc)))
            (push seg segs)
            (push dir dirs))))
      (setq prev next))
    (setf (bm--edge-segs edge) (nreverse segs))
    (setf (bm--edge-seg-dirs edge) (nreverse dirs))))

(defun bm--corner-char (style pd nd)
  "Corner character for a bend from direction PD into ND."
  (let ((table (cdr (assq style (bm--corner-table)))))
    (cond
     ((or (and (equal pd bm--right) (equal nd bm--down))
          (and (equal pd bm--up) (equal nd bm--left)))
      (nth 0 table))
     ((or (and (equal pd bm--right) (equal nd bm--up))
          (and (equal pd bm--down) (equal nd bm--left)))
      (nth 1 table))
     ((or (and (equal pd bm--left) (equal nd bm--down))
          (and (equal pd bm--up) (equal nd bm--right)))
      (nth 2 table))
     ((or (and (equal pd bm--left) (equal nd bm--up))
          (and (equal pd bm--down) (equal nd bm--right)))
      (nth 3 table))
     (t ?+))))

(defun bm--draw-corners (graph edge)
  "Draw bend characters at EDGE's path interior points."
  (let ((path (bm--edge-path edge))
        (i 1))
    (while (< i (1- (length path)))
      (let* ((c (nth i path))
             (pd (bm--determine-direction (nth (1- i) path) c))
             (nd (bm--determine-direction c (nth (1+ i) path)))
             (dc (bm--grid->drawing graph (car c) (cdr c))))
        (bm--canvas-put graph (car dc) (cdr dc)
                        (bm--corner-char (bm--edge-style edge) pd nd))
        (cl-incf i)))))

(defun bm--draw-arrowhead (graph last-line fallback-dir)
  "Draw an arrowhead at the end of LAST-LINE (list of drawn cells)."
  (when (and last-line (not (null last-line)))
    (let* ((from (car last-line))
           (last (car (last last-line)))
           (dir (if (or (= 1 (length last-line))
                        (equal (bm--determine-direction from last)
                               bm--middle))
                    fallback-dir
                  (bm--determine-direction from last)))
           (ch (or (bm--arrow-char dir)
                   (bm--arrow-char fallback-dir)
                   ?◌)))
      (bm--canvas-put graph (car last) (cdr last) ch))))

(defun bm--draw-box-start (graph edge)
  "Draw the T-junction where EDGE leaves its source box."
  (let* ((path (bm--edge-path edge))
         (segs (bm--edge-segs edge)))
    (when (and (>= (length path) 2) segs)
      (let* ((from (car (car segs)))
             (dir (bm--determine-direction (nth 0 path) (nth 1 path)))
             (ch (cond ((equal dir bm--up) ?┴)
                       ((equal dir bm--down) ?┬)
                       ((equal dir bm--left) ?┤)
                       ((equal dir bm--right) ?├))))
        (when ch
          (bm--canvas-put graph
                          (+ (car from)
                             (cond ((equal dir bm--left) 1)
                                   ((equal dir bm--right) -1)
                                   (t 0)))
                          (+ (cdr from)
                             (cond ((equal dir bm--up) 1)
                                   ((equal dir bm--down) -1)
                                   (t 0)))
                          ch))))))

(defun bm--draw-arrow-start (graph edge)
  "Draw the arrowhead at EDGE's source end (bidirectional arrows)."
  (let* ((segs (bm--edge-segs edge))
         (dirs (bm--edge-seg-dirs edge)))
    (when (and segs dirs)
      (let* ((fp (car (car segs)))
             (d0 (car dirs))
             (ax (car fp)) (ay (cdr fp)))
        (cond ((equal d0 bm--right) (cl-decf ax))
              ((equal d0 bm--left) (cl-incf ax))
              ((equal d0 bm--down) (cl-decf ay))
              ((equal d0 bm--up) (cl-incf ay)))
        (bm--draw-arrowhead graph (list fp (cons ax ay))
                            (bm--opposite-dir d0))))))

(defun bm--draw-text-on-line (graph line label upward)
  "Center LABEL on the drawing segment LINE (two drawing coords).
UPWARD is t, nil or \\='unknown; vertical segments offset the label by
edge direction to avoid bidirectional label collisions."
  (when (and line (= 2 (length line)))
    (let* ((a (nth 0 line)) (b (nth 1 line))
           (minx (min (car a) (car b))) (maxx (max (car a) (car b)))
           (miny (min (cdr a) (cdr b))) (maxy (max (cdr a) (cdr b)))
           (midx (+ minx (floor (- maxx minx) 2)))
           (midy (+ miny (floor (- maxy miny) 2))))
      (when (and (not (eq upward 'unknown)) (= minx maxx))
        (let ((offset (max 1 (floor (- maxy miny) 4))))
          (setq midy (if upward (+ midy offset) (- midy offset)))))
      (let* ((lines (split-string label "\n"))
             (starty (- midy (floor (1- (length lines)) 2))))
        (cl-loop for l in lines
                 for i from 0
                 do (bm--draw-string
                     graph (- midx (floor (string-width l) 2))
                     (+ starty i) l))))))

(defun bm--draw-edge-label (graph edge)
  (let ((text (bm--edge-text edge)))
    (when (> (length text) 0)
      (let* ((ll (bm--edge-label-line edge))
             (line (mapcar (lambda (c)
                             (bm--grid->drawing graph (car c) (cdr c)))
                           ll))
             (path (bm--edge-path edge))
             (start-y (cdr (nth 0 path)))
             (end-y (cdr (nth (1- (length path)) path)))
             (upward (cond ((< end-y start-y) t)
                           ((> end-y start-y) nil)
                           (t 'unknown))))
        (bm--draw-text-on-line graph line text upward)))))

(defun bm--node-attachment (graph node dir)
  "Drawing coordinate where an edge attaches to NODE's border along DIR.
Used by bundled edges (mirrors TS getNodeAttachmentPoint +
getBoxAttachmentPoint): the border position computed from the
grid-allocated box size."
  (let* ((gcx (bm--node-gx node)) (gcy (bm--node-gy node))
         (w (+ (gethash gcx (bm--graph-col-w graph) 0)
               (gethash (1+ gcx) (bm--graph-col-w graph) 0)))
         (h (+ (gethash gcy (bm--graph-row-h graph) 0)
               (gethash (1+ gcy) (bm--graph-row-h graph) 0)))
         (width (1+ w)) (height (1+ h))
         (dx (bm--node-dx node)) (dy (bm--node-dy node))
         (cx (+ dx (floor width 2))) (cy (+ dy (floor height 2))))
    (cond ((equal dir bm--up) (cons cx dy))
          ((equal dir bm--down) (cons cx (+ dy height -1)))
          ((equal dir bm--left) (cons dx cy))
          ((equal dir bm--right) (cons (+ dx width -1) cy))
          ((equal dir bm--upper-left) (cons dx dy))
          ((equal dir bm--upper-right) (cons (+ dx width -1) dy))
          ((equal dir bm--lower-left) (cons dx (+ dy height -1)))
          ((equal dir bm--lower-right)
           (cons (+ dx width -1) (+ dy height -1)))
          (t (cons cx cy)))))

(defun bm--bundled-drawing-path (graph edge)
  "Drawing coords for EDGE's path-to-junction.  The node-end point is
substituted with the node's border attachment point (fan-in: source
end; fan-out: target end)."
  (let* ((bundle (bm--edge-bundle edge))
         (path (bm--edge-path-to-junction edge))
         (n (length path)))
    (cl-loop for gc in path
             for idx from 0
             collect (cond
                      ((and (eq (bm--bundle-type bundle) 'fan-in) (= idx 0))
                       (bm--node-attachment graph (bm--edge-from edge)
                                            (bm--edge-start-dir edge)))
                      ((and (eq (bm--bundle-type bundle) 'fan-out) (= idx (1- n)))
                       (bm--node-attachment graph (bm--edge-to edge)
                                            (bm--edge-end-dir edge)))
                      (t (bm--grid->drawing graph (car gc) (cdr gc)))))))

(defun bm--bundle-shared-drawing-path (graph bundle)
  "Drawing coords for BUNDLE's shared path, with the shared-node end
substituted by its border attachment point."
  (let* ((path (bm--bundle-shared-path bundle))
         (n (length path))
         (shared (bm--bundle-shared-node bundle)))
    (cl-loop for gc in path
             for idx from 0
             collect (cond
                      ((and (eq (bm--bundle-type bundle) 'fan-in) (= idx (1- n)))
                       (bm--node-attachment graph shared bm--up))
                      ((and (eq (bm--bundle-type bundle) 'fan-out) (= idx 0))
                       (bm--node-attachment graph shared bm--down))
                      (t (bm--grid->drawing graph (car gc) (cdr gc)))))))

(defun bm--draw-polyline (graph dpath style)
  "Draw consecutive segments between DPATH coords, skipping both
endpoints of every segment (offsets 1, -1) — bundled-edge convention."
  (let ((rest dpath))
    (while (cdr rest)
      (let ((a (car rest)) (b (cadr rest)))
        (unless (equal a b)
          (bm--draw-line graph a b 1 -1 style)))
      (setq rest (cdr rest)))))

(defun bm--draw-path-bend-corners (graph path)
  "Corner characters at interior bends of a grid PATH.
Bundled paths always use single-line corner glyphs (as in TS)."
  (let ((i 1))
    (while (< i (1- (length path)))
      (let* ((c (nth i path))
             (dc (bm--grid->drawing graph (car c) (cdr c)))
             (ch (bm--corner-char
                  'solid
                  (bm--determine-direction (nth (1- i) path) c)
                  (bm--determine-direction c (nth (1+ i) path)))))
        (bm--canvas-put graph (car dc) (cdr dc) ch)
        (cl-incf i)))))

(defun bm--draw-bundle-box-start (graph edge)
  "T-junction where a fan-in bundled edge leaves its source box.
The char is placed directly on the border attachment point."
  (let ((path (bm--edge-path-to-junction edge)))
    (when (>= (length path) 2)
      (let* ((dpath (bm--bundled-drawing-path graph edge))
             (from (car dpath))
             (dir (bm--determine-direction (nth 0 path) (nth 1 path)))
             (ch (cond ((equal dir bm--up) ?┴)
                       ((equal dir bm--down) ?┬)
                       ((equal dir bm--left) ?┤)
                       ((equal dir bm--right) ?├))))
        (when ch
          (bm--canvas-put graph (car from) (cdr from) ch))))))

(defun bm--draw-bundle-arrowhead (graph bundle)
  "Single arrowhead at the shared target of a fan-in bundle."
  (let ((path (bm--bundle-shared-path bundle)))
    (when (>= (length path) 2)
      (let* ((dir (bm--determine-direction (nth (- (length path) 2) path)
                                           (nth (1- (length path)) path)))
             (dc (bm--node-attachment graph (bm--bundle-shared-node bundle)
                                      bm--up)))
        (cl-decf (cdr dc))                ; one cell above the border
        (bm--canvas-put graph (car dc) (cdr dc)
                        (or (bm--arrow-char dir)
                            (bm--arrow-char bm--down)))))))

(defun bm--draw-bundled-edge-arrowhead (graph edge)
  "Arrowhead at the target end of one fan-out bundled edge."
  (let ((path (bm--edge-path-to-junction edge)))
    (when (>= (length path) 2)
      (let* ((dir (bm--determine-direction (nth (- (length path) 2) path)
                                           (nth (1- (length path)) path)))
             (dc (bm--node-attachment graph (bm--edge-to edge) bm--up)))
        (cl-decf (cdr dc))                ; one cell above the border
        (bm--canvas-put graph (car dc) (cdr dc)
                        (or (bm--arrow-char dir)
                            (bm--arrow-char bm--down)))))))

(defun bm--draw-junction-char (graph bundle)
  "Junction character where bundled edges merge or split."
  (let* ((junction (bm--bundle-junction bundle))
         (dc (bm--grid->drawing graph (car junction) (cdr junction)))
         (has-up nil) (has-down nil) (has-left nil) (has-right nil)
         (fan-in-p (eq (bm--bundle-type bundle) 'fan-in))
         (shared-path (bm--bundle-shared-path bundle)))
    (when (>= (length shared-path) 2)
      (let* ((j-idx (if fan-in-p 0 (1- (length shared-path))))
             (a-idx (if fan-in-p 1 (- (length shared-path) 2)))
             (shared-dir (bm--determine-direction (nth j-idx shared-path)
                                                  (nth a-idx shared-path))))
        (cond ((equal shared-dir bm--down) (setq has-down t))
              ((equal shared-dir bm--up) (setq has-up t))
              ((equal shared-dir bm--right) (setq has-right t))
              ((equal shared-dir bm--left) (setq has-left t)))))
    (dolist (edge (bm--bundle-edges bundle))
      (let ((path (bm--edge-path-to-junction edge)))
        (when (>= (length path) 2)
          (let* ((j-idx (if fan-in-p (1- (length path)) 0))
                 (a-idx (if fan-in-p (- (length path) 2) 1))
                 (arrival (bm--determine-direction (nth a-idx path)
                                                   (nth j-idx path))))
            (cond ((equal arrival bm--down) (setq has-up t))
                  ((equal arrival bm--up) (setq has-down t))
                  ((equal arrival bm--right) (setq has-left t))
                  ((equal arrival bm--left) (setq has-right t)))))))
    (bm--canvas-put graph (car dc) (cdr dc)
                    (cond
                     ((and has-up has-down has-left has-right) ?┼)
                     ((and has-down has-left has-right (not has-up)) ?┬)
                     ((and has-up has-left has-right (not has-down)) ?┴)
                     ((and has-up has-down has-right (not has-left)) ?├)
                     ((and has-up has-down has-left (not has-right)) ?┤)
                     ((and has-left has-right) ?─)
                     ((and has-up has-down) ?│)
                     ((and has-down has-right) ?┌)
                     ((and has-down has-left) ?┐)
                     ((and has-up has-right) ?└)
                     ((and has-up has-left) ?┘)
                     (t ?┼)))))

(defun bm--bundled-edge-p (edge)
  "Non-nil when EDGE is part of a routed bundle."
  (and (bm--edge-bundle edge)
       (> (length (bm--edge-path-to-junction edge)) 0)))

(defun bm--bundle-first-edge-p (edge)
  "Non-nil when EDGE is the first edge of its bundle (bundle edges
keep their original order, so this is the first one encountered while
iterating the edge list)."
  (eq edge (car (bm--bundle-edges (bm--edge-bundle edge)))))

(defun bm--draw-graph (graph)
  "Paint the whole diagram.  Layer order matches the TS renderer:
boxes, lines, corners, junctions, end arrowheads, box-starts, start
arrowheads, edge labels.  Bundled edges contribute their own segment
per edge; shared paths and junction characters render once per bundle."
  ;; 1. node boxes
  (dolist (node (bm--graph-nodes graph))
    (bm--draw-node-box graph node))
  ;; 2. edge lines
  (dolist (edge (bm--graph-edges graph))
    (cond
     ((bm--bundled-edge-p edge)
      (bm--draw-polyline graph (bm--bundled-drawing-path graph edge)
                         (bm--edge-style edge))
      (when (bm--bundle-first-edge-p edge)
        (bm--draw-polyline
         graph
         (bm--bundle-shared-drawing-path graph (bm--edge-bundle edge))
         (bm--edge-style (car (bm--bundle-edges (bm--edge-bundle edge)))))))
     ((> (length (bm--edge-path edge)) 0)
      (bm--draw-edge-lines graph edge))))
  ;; 3. corners
  (dolist (edge (bm--graph-edges graph))
    (cond
     ((bm--bundled-edge-p edge)
      (bm--draw-path-bend-corners graph (bm--edge-path-to-junction edge))
      (when (bm--bundle-first-edge-p edge)
        (bm--draw-path-bend-corners
         graph (bm--bundle-shared-path (bm--edge-bundle edge)))))
     (t (bm--draw-corners graph edge))))
  ;; 4. junction characters (bundles, once per bundle)
  (dolist (edge (bm--graph-edges graph))
    (when (and (bm--bundled-edge-p edge)
               (bm--bundle-first-edge-p edge))
      (bm--draw-junction-char graph (bm--edge-bundle edge))))
  ;; 5. end arrowheads
  (dolist (edge (bm--graph-edges graph))
    (cond
     ((bm--bundled-edge-p edge)
      (let ((bundle (bm--edge-bundle edge)))
        (if (eq (bm--bundle-type bundle) 'fan-in)
            (when (bm--bundle-first-edge-p edge)
              (bm--draw-bundle-arrowhead graph bundle))
          (when (bm--edge-arrow-end edge)
            (bm--draw-bundled-edge-arrowhead graph edge)))))
     ((bm--edge-arrow-end edge)
      (bm--draw-arrowhead graph (car (last (bm--edge-segs edge)))
                          (car (last (bm--edge-seg-dirs edge)))))))
  ;; 6. box-start junctions (fan-in bundled edges draw on the source
  ;;    border; fan-out bundled edges draw none)
  (dolist (edge (bm--graph-edges graph))
    (cond
     ((bm--bundled-edge-p edge)
      (when (eq (bm--bundle-type (bm--edge-bundle edge)) 'fan-in)
        (bm--draw-bundle-box-start graph edge)))
     (t (bm--draw-box-start graph edge))))
  ;; 7. start arrowheads (non-bundled only, as in TS)
  (dolist (edge (bm--graph-edges graph))
    (unless (bm--edge-bundle edge)
      (when (bm--edge-arrow-start edge)
        (bm--draw-arrow-start graph edge))))
  ;; 8. edge labels (bundled edges never have labels)
  (dolist (edge (bm--graph-edges graph))
    (unless (bm--edge-bundle edge)
      (bm--draw-edge-label graph edge))))


;;; ================================ Output =================================

(defun bm--canvas-dims (graph)
  "Final canvas dimensions (W . H) in cells."
  (let ((w 0) (h 0))
    (maphash (lambda (_k v) (cl-incf w v)) (bm--graph-col-w graph))
    (maphash (lambda (_k v) (cl-incf h v)) (bm--graph-row-h graph))
    (cons (max w (1+ (bm--graph-canvas-max-x graph)))
          (max h (1+ (bm--graph-canvas-max-y graph))))))

(defun bm--canvas-to-string (graph)
  "Serialize the canvas to a multi-line string.  Cells absorbed by
wide glyphs (bm--wide-marker) are skipped: the wide character already
occupies their display columns."
  (let* ((dims (bm--canvas-dims graph))
         (w (car dims)) (h (cdr dims))
         (canvas (bm--graph-canvas graph)))
    (with-temp-buffer
      (dotimes (y h)
        (dotimes (x w)
          (let ((ch (gethash (cons x y) canvas)))
            (unless (eq ch bm--wide-marker)
              (insert-char (or ch ?\s) 1))))
        (unless (= y (1- h)) (insert "\n")))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun bm--flip-canvas (graph)
  "Flip the canvas vertically (BT direction) and remap direction chars."
  (let* ((dims (bm--canvas-dims graph))
         (h (cdr dims))
         (old (bm--graph-canvas graph))
         (new (make-hash-table :test #'equal)))
    (maphash (lambda (k ch)
               (puthash (cons (car k) (- h 1 (cdr k)))
                        (or (cdr (assq ch bm--flip-map)) ch)
                        new))
             old)
    (setf (bm--graph-canvas graph) new)))

(defun bm--render (text)
  "Render mermaid TEXT to Unicode box art."
  (let ((graph (bm--parse text)))
    (bm--layout graph)
    (bm--draw-graph graph)
    (when (bm--graph-flip-vertical graph)
      (bm--flip-canvas graph))
    (bm--canvas-to-string graph)))

;;;###autoload
(defun beautiful-mermaid-render (text)
  "Render mermaid flowchart TEXT as Unicode box-drawing art.
Return a multi-line string.  Only `graph'/`flowchart' diagrams are
supported; other diagram types raise an error.

\(fn TEXT)"
  (bm--render text))

;;;###autoload
(defun beautiful-mermaid-render-region (beg end)
  "Render the mermaid flowchart between BEG and END.
The diagram is displayed in the buffer *mermaid-ascii*."
  (interactive "r")
  (beautiful-mermaid--display
   (bm--render (buffer-substring-no-properties beg end))))

;;;###autoload
(defun beautiful-mermaid-render-buffer ()
  "Render the mermaid flowchart in the current buffer."
  (interactive)
  (beautiful-mermaid-render-region (point-min) (point-max)))

(defun beautiful-mermaid--display (art)
  "Show ART in the *mermaid-ascii* buffer."
  (with-current-buffer (get-buffer-create "*mermaid-ascii*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert art)
      (goto-char (point-min)))
    (special-mode)
    (pop-to-buffer (current-buffer))))


;;; ================================ Org integration ==========================
;;
;; Toggle between mermaid source and rendered ASCII art inside org
;; buffers, the way `org-toggle-inline-images' toggles pictures:
;; `beautiful-mermaid-org-toggle' overlays a src block with its
;; rendering; calling it again restores the source.  Org-babel is
;; supported too: C-c C-c on a mermaid block returns the rendering.

(declare-function org-element-at-point "org-element" ())
(declare-function org-element-property "org-element" (property element))
(declare-function org-element-type "org-element" (element))
(declare-function org-element-parse-buffer "org-element"
                  (&optional granularity visible-only))
(declare-function org-element-map "org-element"
                  (data types fun &optional no-control no-section first-match))

(defcustom beautiful-mermaid-org-languages '("mermaid" "flowchart")
  "Src-block languages handled by `beautiful-mermaid-org-toggle'."
  :type '(repeat string)
  :group 'beautiful-mermaid)

(defun beautiful-mermaid-org--art-overlays ()
  "All render overlays in the current buffer."
  (cl-remove-if-not
   (lambda (ov) (overlay-get ov 'beautiful-mermaid))
   (overlays-in (point-min) (point-max))))

(defun beautiful-mermaid-org--block-at-point ()
  "Return the mermaid src-block element at point, or nil."
  (and (derived-mode-p 'org-mode)
       (let ((el (org-element-at-point)))
         (and (eq (org-element-type el) 'src-block)
              (member (org-element-property :language el)
                      beautiful-mermaid-org-languages)
              el))))

(defun beautiful-mermaid-org--render-block (el)
  "Cover the src-block element EL with a rendering overlay."
  (let* ((src (org-element-property :value el))
         (art (beautiful-mermaid-render src))
         (ov (make-overlay (org-element-property :begin el)
                           (org-element-property :end el))))
    ;; diagrams nested in lists/quotes: indent art to the block column
    (save-excursion
      (goto-char (org-element-property :begin el))
      (let ((col (current-indentation)))
        (when (> col 0)
          (setq art (mapconcat (lambda (l) (concat (make-string col ?\s) l))
                               (split-string art "\n") "\n")))))
    (overlay-put ov 'beautiful-mermaid t)
    (overlay-put ov 'display (propertize art 'face 'fixed-pitch))
    (let ((map (make-sparse-keymap)))
      (define-key map [mouse-1] #'beautiful-mermaid-org-toggle)
      (overlay-put ov 'local-map map))
    (overlay-put ov 'mouse-face 'highlight)
    (overlay-put ov 'help-echo "mouse-1: toggle mermaid source")
    ov))

;;;###autoload
(defun beautiful-mermaid-org-toggle (&optional arg)
  "Toggle ASCII rendering of the mermaid src block at point.
Cover the block with its rendering; call again to restore the
source.  With a prefix ARG (\\[universal-argument]) act on every
mermaid block in the buffer: render all, or restore all if any
is already rendered.  Blocks edited while rendered show stale
art; toggle twice to refresh.

Suggested binding:

  (define-key org-mode-map (kbd \"C-c C-x M-m\")
              #\='beautiful-mermaid-org-toggle)"
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an org buffer"))
  (if (equal arg '(4))
      (if (beautiful-mermaid-org--art-overlays)
          (dolist (ov (beautiful-mermaid-org--art-overlays))
            (delete-overlay ov))
        (org-element-map (org-element-parse-buffer) 'src-block
          (lambda (el)
            (when (member (org-element-property :language el)
                          beautiful-mermaid-org-languages)
              (beautiful-mermaid-org--render-block el))
            nil)))
    (let ((ovs (cl-remove-if-not
                (lambda (ov) (overlay-get ov 'beautiful-mermaid))
                (overlays-at (point)))))
      (if ovs
          (dolist (ov ovs) (delete-overlay ov))
        (let ((el (beautiful-mermaid-org--block-at-point)))
          (unless el
            (user-error "Point is not inside a mermaid src block"))
          (beautiful-mermaid-org--render-block el)
          ;; park point on the overlay start so the display is not
          ;; split around the cursor
          (goto-char (org-element-property :begin el)))))))

(defun org-babel-execute:mermaid (body _params)
  "Render mermaid BODY to ASCII art for org-babel.
C-c C-c on a mermaid src block inserts the rendering as the
result.  Use a \`:results raw' header to insert it as org text,
for example:

  #+begin_src mermaid :results raw
    graph LR
      A --> B
  #+end_src

Note: this provides the `org-babel-execute:mermaid' hook also
claimed by the MELPA `ob-mermaid' package (SVG via mermaid-cli);
whichever loads later wins."
  (beautiful-mermaid-render body))

;; Tests live in beautiful-mermaid-test.el (ERT).  Run from a shell:
;;   emacs -Q --batch -l beautiful-mermaid-test.el -f ert-run-tests-batch-and-exit

(provide 'beautiful-mermaid)

;;; beautiful-mermaid.el ends here
