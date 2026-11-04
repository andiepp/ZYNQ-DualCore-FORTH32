\ Autostart test source: visible on the board after power-up.
: hello-lab ." Hello from the saved source" cr ;
: count-leds 16 0 do i led! 60 ms loop ;
hello-lab count-leds 5 led!
