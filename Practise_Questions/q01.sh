#!/bin/bash

# Write a script to check whether a file exists, is readable, writable, and executable

file_check="/run/media/deepakrk/Local Drive/Study/Linux/Linux-Shell-Scripting-2026/Practise_Questions/dummy.txt"

if [[ -f "$file_check" && -r "$file_check" && -w "$file_check" && -x "$file_check" ]]; then
    echo "$file_check is a regular file and has read, write, and execute permissions."
else
    echo "$file_check is either not a regular file or does not have the required permissions."
fi