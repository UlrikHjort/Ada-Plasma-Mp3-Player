PROJECT := mp3player
MAIN := plasma_player
OBJ_DIR := obj
BIN_DIR := bin
SRC_DIR := src
C_DIR := c

C_OBJ := $(OBJ_DIR)/player_bridge.o
CFLAGS := -O2 -Wall -Wextra -std=c11 $(shell pkg-config --cflags sdl2 libmpg123)
LDLIBS := $(shell pkg-config --libs sdl2 libmpg123) -lm

.PHONY: all build gpr clean run record

all: build

build: $(BIN_DIR)/$(MAIN)

$(OBJ_DIR) $(BIN_DIR):
	mkdir -p $@

$(C_OBJ): $(C_DIR)/player_bridge.c | $(OBJ_DIR)
	gcc $(CFLAGS) -c $< -o $@

$(BIN_DIR)/$(MAIN): $(SRC_DIR)/$(MAIN).adb $(SRC_DIR)/c_bridge.ads $(C_OBJ) | $(BIN_DIR)
	gnatmake -gnat2022 -O2 -aI$(SRC_DIR) -D $(OBJ_DIR) -o $@ $< -largs $(C_OBJ) $(LDLIBS)

gpr:
	gprbuild -P $(PROJECT).gpr

run: build
	./$(BIN_DIR)/$(MAIN) t.mp3

record: build
	./$(BIN_DIR)/$(MAIN) --record plasma.mp4 t.mp3

clean:
	rm -f $(BIN_DIR)/$(MAIN)
	rm -rf $(OBJ_DIR)
