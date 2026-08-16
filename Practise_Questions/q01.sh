#!/bin/bash

file_check="/run/media/deepakrk/Local Drive/Study/Linux/Linux-Shell-Scripting-2026/Practise_Questions/dummy.txt"

if [[ -f "$file_check" ]]; then
    echo "$file_check exists"
fi