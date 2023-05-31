#!/bin/bash

hyperfine -r 1000 -N \
    "./zig-out/bin/bench-smallarray" \
    "./zig-out/bin/bench-arraylist-arena" \
    "./zig-out/bin/bench-arraylist-arena-with-cap" \
    "./zig-out/bin/bench-arraylist-fixed-buffer" \
    "./zig-out/bin/bench-boundedarray" \
    --export-json result.json
