\ floats.fs - floating point on the HF32: a few numbers, a function table and the board
\ in volts and degrees (manual, section 5.15)

: circle ( F: r -- area ) fdup f* pi f* ;
: deg>rad ( F: deg -- rad ) pi f* 180e f/ ;

\ sine and cosine every 15 degrees
: table ( -- )
  cr 91 0 do
    i . i s>f deg>rad fsincos fswap f. f. cr
  15 +loop ;

\ the chip temperature and A0 in volts, every second until a key is pressed
: meter ( -- )
  begin
    ftemp@ f. ." C  " 0 volts@ f. ." V" cr 1000 ms
  key? until key drop ;

." floats ready: 2e circle f.  table  meter" cr
