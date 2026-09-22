# beautiful-mermaid.el

Render [Mermaid](https://mermaid.js.org/) flowcharts as Unicode box-drawing
art — directly in Emacs, with **zero dependencies** and in a **single file**.

```
┌───────┐             
│       │             
│ Start │             
│       │             
└───┬───┘             
    │                 
    │                 
    │                 
    │                 
    ▼                 
◊───────◊             
│       │             
│ Check ├─────────┐   
│       │         │   
◊───┬───◊       fail  
    │             │   
   yes            │   
    │             │   
    │             │   
    ▼             ▼   
┌───────┐     ┌──────┐
│       │     │      │
│   Go  │     │ Fix  │
│       │     │      │
└───────┘     └──────┘
```

This is a single-file Emacs Lisp port of the ASCII/Unicode renderer inside
the TypeScript project [beautiful-mermaid](https://github.com/lukilabs/beautiful-mermaid)
(which itself derives from Alexander Grooff's
[mermaid-ascii](https://github.com/AlexanderGrooff/mermaid-ascii)). The port
is verified against the TypeScript renderer: **all 27 golden test diagrams
match byte-for-byte**.

## Features

- `graph` / `flowchart` diagrams in all directions (TD / TB / LR / RL / BT)
- All 12 node shapes (rectangle, rounded, diamond, circle, stadium, hexagon,
  subroutine, doublecircle, cylinder, asymmetric, trapezoid, trapezoid-alt)
- Solid, dotted and thick edges, open lines, bidirectional arrows, edge
  labels in both syntaxes (`A -->|text| B` and `A -- text --> B`)
- Chains, cycles, self-loops, back edges, `A & B --> C & D` node groups,
  multi-line labels (`<br>`), CJK labels aligned by display width
- Edge bundling: parallel fan-in / fan-out edges share one path with a
  single arrowhead and a junction character
- Org-mode integration: toggle between source and rendered art inside
  `src` blocks, plus org-babel execution
- Two character profiles: `safe` (default; only glyphs covered by common
  terminal fonts) and `full` (matches the TypeScript renderer exactly)

Deliberately **not** supported: other diagram types (state, sequence,
class, ER, xychart), subgraphs, styling directives, colors, themes.
Unsupported directives are ignored rather than rejected.

## Requirements

- Emacs 26.1 or later. No other packages, no external processes, no
  mermaid-cli / Node.js.

## Installation

### Manual

```sh
git clone https://github.com/scturtle/beautiful-mermaid.el.git
```

```elisp
(add-to-list 'load-path "/path/to/beautiful-mermaid.el")
(require 'beautiful-mermaid)
```

### use-package (Emacs 29+)

```elisp
(use-package beautiful-mermaid
  :vc (:url "https://github.com/scturtle/beautiful-mermaid.el" :rev :newest)
  :bind (:map org-mode-map
              ("C-c C-x M-m" . beautiful-mermaid-org-toggle)))
```

### Straight / elpaca

```elisp
;; straight.el
(straight-use-package
 '(beautiful-mermaid :type git
   :url "https://github.com/scturtle/beautiful-mermaid.el"))

;; elpaca
(elpaca ( :host github :repo "scturtle/beautiful-mermaid.el"))
```

## Usage

### Quick API

```elisp
(beautiful-mermaid-render "graph LR\n  A[Start] --> B[End]")
;; => "┌───────┐     ┌─────┐\n│       │     │     │..."
```

### Interactive commands

| Command | Effect |
|---|---|
| `M-x beautiful-mermaid-render-region` | Render the selected mermaid source; result pops up in `*mermaid-ascii*` |
| `M-x beautiful-mermaid-render-buffer` | Render the whole buffer |

### Org-mode

Toggle a mermaid src block between source and rendered art — like
`org-toggle-inline-images` for diagrams:

```elisp
(define-key org-mode-map (kbd "C-c C-x M-m")
            #'beautiful-mermaid-org-toggle)
```

```org
- A flowchart:
  #+begin_src mermaid
    graph LR
      A[开始] --> B{判断}
      B -->|yes| C[结束]
      B -->|no| A
  #+end_src
```

With point inside the block, `C-c C-x M-m` covers the source with the
rendered diagram (monospaced, indented to the block's column so it stays
aligned inside lists); press it again to restore the source. A `C-u`
prefix toggles every mermaid block in the buffer. Clicking the art with
the mouse toggles it too.

Org-babel works as well: `C-c C-c` on a mermaid block inserts the
rendering as the result. Use a `:results raw` header to insert it as
plain org text:

```org
#+begin_src mermaid :results raw
  graph TD
    X[Source] --> Y[Art]
#+end_src
```

> Note: this package provides the `org-babel-execute:mermaid` hook also
> claimed by the MELPA `ob-mermaid` package (which renders SVGs via
> mermaid-cli). Whichever loads later wins.

### Customization

| Variable | Default | Meaning |
|---|---|---|
| `bm-char-profile` | `safe` | `safe` sticks to widely-covered glyphs; `full` uses every character the TypeScript renderer uses |
| `bm-arrow-style` | `triangle` | `triangle` draws solid triangles `▶◀▲▼` (diagonals fall back to thin `↖↗↘↙`); `arrow` draws thin arrows in all directions |
| `bm-padding-x` / `bm-padding-y` | 5 | Space between grid blocks |
| `bm-box-padding` | 1 | Blank cells around the label inside a box |
| `beautiful-mermaid-org-languages` | `("mermaid" "flowchart")` | Src-block languages the org toggle handles |

## Character profiles

The default `safe` profile only emits characters that are covered by the
font this port was developed against (166 code points, see `docs.md`):
single- and double-line box sets, thin arrows, solid triangles. The
`full` profile additionally uses rounded corners, dashed/dotted lines,
heavy lines and so on — matching the TypeScript renderer exactly, which
is what the golden tests lock. Both profiles share the same geometry;
they differ only in glyph substitution.

## Correctness

`beautiful-mermaid-test.el` contains 55 end-to-end ERT tests. They all
drive the public API and assert on final output — no internal function
is called, so refactors that preserve output do not break tests.

The byte-exact goldens cover 27 diagrams verified against the
TypeScript renderer (after normalizing four arrow glyphs that fall
outside the covered font set): every node shape, every line style,
both label syntaxes, bidirectional/open edges, chains, cycles, self
loops, back edges, edge bundling in all three styles, the
`flowchart` keyword, node groups, multi-root and standalone graphs,
skip-level edges, LR edge labels, deep-tree collision shifting, and
the RL/BT directions.

```sh
emacs -Q --batch -l beautiful-mermaid-test.el -f ert-run-tests-batch-and-exit
# Ran 55 tests, 55 results as expected, 0 unexpected
```

## Documentation

See [docs.md](docs.md) (in Chinese) for the full porting design:
architecture mapping to the TypeScript modules, the 3×3 grid layout
model, A\* edge routing, junction merging, edge bundling, the
`safe`/`full` glyph tables, deliberate deviations from the upstream
renderer, and the golden-test methodology.

## Acknowledgments

- [beautiful-mermaid](https://github.com/lukilabs/beautiful-mermaid) by
  Craft Docs — the upstream TypeScript renderer this port is based on.
- [mermaid-ascii](https://github.com/AlexanderGrooff/mermaid-ascii) by
  Alexander Grooff — the original project beautiful-mermaid derives from.

## License

MIT — see [LICENSE](LICENSE).
