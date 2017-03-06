.PHONY: clean check default show

FILES=$(sort $(wildcard *cu))
BINARIES=$(patsubst %.cu,%,$(FILES))

#TARGET=raytracer2
TARGET=$(lastword $(BINARIES))
THREADS=4

ifeq ($(DEBUG),yes)
	CXXFLAGS=-std=c++11 -g -O0
else
	CXXFLAGS=-std=c++11 -O3
	# CXXFLAGS=-std=c++11 -pthread -O3 -Wall -march=native -DNOPPM
endif

$(TARGET):
	nvcc $(NVCCFLAGS) $(FILES) -o $(TARGET)

default: $(TARGET) check

check:
	time -p ./$(TARGET) $(THREADS)
	md5sum untitled.ppm
	@echo "09042d2566e20716029330d16850b1b8  reference.ppm (reference for 100 spheres)"

show:
	@echo "FILES:    $(FILES)"
	@echo "BINARIES: $(BINARIES)"
	@echo "TARGET:   $(TARGET)"

clean:
	rm -f $(BINARIES)
	rm -f *~ untitled.ppm
