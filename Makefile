.PHONY: all clean repl test

all:
	dune build
	dune build src/toploop-main/ddpa_toploop.exe
	rm -f ddpa_toploop
	ln -s _build/default/src/toploop-main/ddpa_toploop.exe ddpa_toploop
	dune build src/test-generation-main/test_generator.exe
	rm -f test_generator
	ln -s _build/default/src/test-generation-main/test_generator.exe test_generator

sandbox:
	dune build test/sandbox.exe

repl:
	dune utop src -- -require pdr-programming

test:
	dune runtest -f

clean:
	dune clean
	rm -f ddpa_toploop
