#!/bin/zsh
# gpuexport.sh <label> : export the tables gputrace.py needs from build/ab/<label>.trace
cd ${0:A:h:h:h}/build/ab
x() { xcrun xctrace export --input $1.trace --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$2\"]" > $1.$3.xml }
x $1 metal-gpu-intervals gpu
x $1 metal-gpu-submission-to-command-buffer-id metal-gpu-submission-to-command-buffer-id
x $1 metal-application-command-buffer-submissions metal-application-command-buffer-submissions
