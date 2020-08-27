SRCS=$(wildcard *.c)

OUTS=$(SRCS:%.c=out/%)

out/% : %.c
	gcc $< -o $@

all: $(OUTS)

clean:
	rm $(OUTS)
