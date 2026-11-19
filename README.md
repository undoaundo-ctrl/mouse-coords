# mouse-coords

A tiny Linux x86-64 assembly program that reports the terminal mouse pointer
position as `X: <col> Y: <row>` while you move the mouse.

It uses the terminal's **SGR 1006** mouse-reporting protocol (no root access,
no `/dev/input` needed) and only raw Linux syscalls: `read`, `write`, `ioctl`,
and `exit`.

## Build

```bash
nasm -felf64 mouse_coords.asm -o mouse_coords.o
ld mouse_coords.o -o mouse_coords
```

## Run

```bash
./mouse_coords
```

Move the mouse inside the terminal window. Press **Ctrl-C** to quit; the
original terminal mode is restored automatically and mouse tracking is
disabled.

> Requires a terminal with mouse-reporting support (xterm, gnome-terminal,
> Konsole, most modern terminals). Coordinates are the terminal's 1-based
> column/row, not screen pixels.

## How it works

1. `ioctl(TCGETS/TCSETS)` puts stdin into raw mode (clears `ICANON`, `ECHO`,
   and `ISIG`) so escape sequences arrive immediately.
2. Writes `ESC[?1006h` and `ESC[?1003h` to enable SGR reports and any-motion
   events.
3. Reads stdin one byte at a time and parses reports like `ESC[<Cb;Cx;CyM`
   with a small state machine.
4. Prints the `Cx`/`Cy` fields as decimal numbers.
5. On exit, restores the original termios and writes `ESC[?1003l` /
   `ESC[?1006l`.

## Debugging with GDB

```bash
gdb ./mouse_coords
(gdb) set disassembly-flavor intel
(gdb) break _start.main_loop
(gdb) run
(gdb) display/i $rip
(gdb) si
(gdb) info registers
```

Useful breakpoints: `_start.num` (parsing a digit), `_start.final` (complete
report), `print_coords`, and `catch syscall read` / `write`.

To attach to an already-running instance: `gdb -p <PID>`.
Run GDB from a different terminal, since the program puts its own terminal
into raw mode.

## License

Public domain / do whatever you want with it.
