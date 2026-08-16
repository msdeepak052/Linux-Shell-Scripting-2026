#!/bin/bash

# Write a script to find the largest of 3 numbers

largest_numbers() {
	
	largest=-99999
	second=-99999
	
	for num in "$@"; do
		if (( num > largest )); then
			second=$largest
            largest=$num
			
		elif (( num > second && num < largest )); then
			second=$num
		fi
    done
	
	echo "Largest : $largest"
	echo "Second Largest: $second"
	

}

arr=(23 12 54)

largest_numbers "${arr[@]}"