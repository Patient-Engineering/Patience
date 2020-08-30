SRCS=$(wildcard */*.c)

OUTS=$(SRCS:%.c=out/%)

out/% : %.c
	mkdir -p out/$(dir $<)
	gcc $< -o out/$(basename $<)

all: $(OUTS)

clean:
	rm $(OUTS)
