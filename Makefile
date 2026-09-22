EMACS ?= emacs

.PHONY: test compile clean

test:
	$(EMACS) -Q --batch -l beautiful-mermaid-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch --eval "(byte-compile-file \"beautiful-mermaid.el\")"
	$(EMACS) -Q --batch --eval "(byte-compile-file \"beautiful-mermaid-test.el\")"
	rm -f *.elc

clean:
	rm -f *.elc
