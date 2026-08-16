#!/bin/bash

#  Write a script to check whether a number is even or odd

even_odd_check() {
	for num in "$@"; do
		if (( num % 2 == 0 )); then
			echo "$num is even"
		else
			echo "$num is odd"
		fi
	done

}

arr=(2 3 11 34 12 19 20)

even_odd_check "${arr[@]}"