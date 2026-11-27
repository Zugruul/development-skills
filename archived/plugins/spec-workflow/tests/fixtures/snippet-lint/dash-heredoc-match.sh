#!/usr/bin/env bash
python3 <<-'PY'
	x = 1
	match x:
	    case 1:
	        print(1)
	PY
