EMACS ?= emacs

.PHONY: test compile clean

test:
	$(EMACS) --batch -L . -l test/esx-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) --batch -L . -f batch-byte-compile esx-client.el esx-ns.el esx-repl.el esx-eval.el esx.el

clean:
	rm -f *.elc test/*.elc
