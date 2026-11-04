\ board-tour.fs - a little of everything the board view shows
5 led!                          \ LD0 and LD2
12 rgb!                         \ LD4 blue, LD5 red
7 output 7 high                 \ IO7 drives 3.3 V
8 output 8 low                  \ IO8 drives 0 V
1000 0 pwm-hz  250 0 pwm-duty  13 0 pwm-pin   \ PWM0: 1 kHz, 25 % on IO13
: star ( -- ) 42 emit ;
: stars ( n -- ) 0 do star loop ;
10 stars cr
.temp cr
3 4 *  100 -42
