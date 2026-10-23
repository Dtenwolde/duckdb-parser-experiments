# Build the paper. Requires a TeX Live install with latexmk.
.PHONY: all clean watch
all:
	latexmk -pdf main.tex
watch:
	latexmk -pdf -pvc main.tex
clean:
	latexmk -C main.tex
