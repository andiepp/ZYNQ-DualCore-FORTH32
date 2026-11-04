\ HF32 Forth kernel, cross-compiled by tools/hf32.py.
\
\ Host rules (see tools/hf32.py): outside definitions only numbers, float literals,
\ : :inline variable fvariable constant fconstant create allot , f, c, immediate
\ and comments are understood. Inside definitions primitives are compiled inline;
\ IF ELSE THEN BEGIN UNTIL AGAIN WHILE REPEAT DO LOOP +LOOP I UNLOOP RECURSE ."
\ [CHAR] ['] [OP] are handled by the host. Calls to words defined later are allowed.

\ ---------------------------------------------------------------------------
\ Primitives as target words. :INLINE words are copied into new definitions
\ by the target compiler (needed for words that touch the return stack).
\ ---------------------------------------------------------------------------

:inline dup dup ;          :inline drop drop ;        :inline swap swap ;
:inline over over ;        :inline nip nip ;          :inline >r >r ;
:inline r> r> ;            :inline r@ r@ ;            :inline + + ;
:inline - - ;              :inline and and ;          :inline or or ;
:inline xor xor ;          :inline = = ;              :inline < < ;
:inline u< u< ;            :inline rshift rshift ;    :inline lshift lshift ;
:inline * * ;              :inline invert invert ;    :inline 1+ 1+ ;
:inline 1- 1- ;            :inline 0= 0= ;            :inline 0< 0< ;
:inline 2/ 2/ ;            :inline negate negate ;    :inline @ @ ;
:inline c@ c@ ;            :inline ! ! ;              :inline c! c! ;
:inline depth depth ;      :inline i r@ ;             :inline arshift arshift ;
:inline unloop r> drop r> drop ;

\ The float stack: FT on top, then 32 entries, like the data stack
:inline fdup fdup ;        :inline fdrop fdrop ;      :inline fswap fswap ;
:inline fover fover ;      :inline f+ f+ ;            :inline f- f- ;
:inline f* f* ;            :inline f/ f/ ;            :inline fsqrt fsqrt ;
:inline fnegate fnegate ;  :inline fabs fabs ;        :inline ftrunc ftrunc ;
:inline s>f s>f ;          :inline f>s f>s ;          :inline f@ f@ ;
:inline f! f! ;            :inline f0< f0< ;          :inline f0= f0= ;
:inline f< f< ;            :inline f= f= ;            :inline fdepth fdepth ;
:inline f>bits f>bits ;    :inline bits>f bits>f ;
:inline sf@ f@ ;           :inline sf! f! ;

\ EXIT cannot be an :INLINE word (inline copying stops at the first EXIT)
: exit [op] exit , ; immediate

: execute ( xt -- ) >r ;

\ ---------------------------------------------------------------------------
\ Stack and arithmetic
\ ---------------------------------------------------------------------------

: rot ( a b c -- b c a ) >r swap r> swap ;
: -rot ( a b c -- c a b ) swap >r swap r> ;
: tuck ( a b -- b a b ) swap over ;
: 2dup ( a b -- a b a b ) over over ;
: 2drop ( a b -- ) drop drop ;
: ?dup ( x -- x x | 0 ) dup if dup then ;
: <> ( a b -- f ) = invert ;
: > ( a b -- f ) swap < ;
: u> ( a b -- f ) swap u< ;
: 0<> ( x -- f ) 0= invert ;
: 0> ( n -- f ) 0 > ;
: 2* ( n -- n*2 ) dup + ;
: abs ( n -- u ) dup 0< if negate then ;
: min ( a b -- min ) 2dup > if swap then drop ;
: max ( a b -- max ) 2dup < if swap then drop ;
: +! ( n addr -- ) dup >r @ + r> ! ;
: cell+ ( a -- a+4 ) 4 + ;
: cells ( n -- n*4 ) 2 lshift ;
: aligned ( a -- a' ) 3 + -4 and ;
: /string ( a n k -- a+k n-k ) rot over + -rot - ;
: s>d ( n -- d ) dup 0< ;

\ Unsigned 32/32 division by shift and subtract: ( d q r ) during the loop
: u/mod ( u d -- rem quot )
  swap 0
  32 0 do
    over 0< if 2* 1+ else 2* then
    swap 2* swap
    rot 2dup u< if -rot else tuck - rot 1+ swap then
  loop
  rot drop swap ;

\ Symmetric signed division
: /mod ( n d -- rem quot )
  2dup xor >r over >r
  abs swap abs swap u/mod
  r> 0< if swap negate swap then
  r> 0< if negate then ;
: / ( n d -- quot ) /mod nip ;
: mod ( n d -- rem ) /mod drop ;

\ Mixed precision: a double cell is ( low high ) with the high cell on top
: um* ( u1 u2 -- ud ) 2dup * -rot (um*) ;

\ Unsigned 64/32 division, the quotient must fit in 32 bits: ( d lo hi ) during
\ the loop, the bit shifted out of HI is kept on the return stack
: um/mod ( ud u -- rem quot )
  -rot
  32 0 do
    dup 0< >r 2* over 0< if 1+ then swap 2* swap
    rot 2dup u< 0= r> or if tuck - rot 1+ swap else -rot then
  loop
  rot drop swap ;

\ n1*n2/n3 with a 64-bit intermediate product, symmetric like /
: */ ( n1 n2 n3 -- n4 )
  >r 2dup xor r@ xor >r
  abs swap abs um*
  r> r> swap >r abs um/mod nip
  r> 0< if negate then ;

: within ( n lo hi -- f ) over - >r - r> u< ;
: dnegate ( d -- d' ) invert swap invert 1+ dup 0= if swap 1+ swap then swap ;

\ DO LOOP runtime. Return stack inside a loop: index on top, then limit.
: (loop) ( -- done? ) r> r> 1+ dup r@ = swap >r swap >r ;
: (+loop) ( n -- done? ) r> swap r> + dup r@ < invert swap >r swap >r ;
: j ( -- n ) r> r> r> r@ swap >r swap >r swap >r ;

\ ---------------------------------------------------------------------------
\ Variables
\ ---------------------------------------------------------------------------

variable dp          \ next free byte (set by the cross-compiler)
variable latest      \ newest header (set by the cross-compiler)
variable state
variable base
variable >in
variable #tib
variable 'a
variable 'n
create tib 84 allot

: here ( -- a ) dp @ ;
: allot ( n -- ) dp +! ;
: align ( -- ) here aligned dp ! ;
: , ( x -- ) align here ! 4 allot ;
: c, ( c -- ) here c! 1 allot ;
: hex 16 base ! ;
: decimal 10 base ! ;
: fill ( a n c -- ) -rot begin dup while >r 2dup c! 1+ r> 1- repeat 2drop drop ;

\ ---------------------------------------------------------------------------
\ Board I/O: register k at $100000 + 4k
\ ---------------------------------------------------------------------------

: key? ( -- f ) $100004 @ 1 and 0<> ;
: key ( -- c ) begin key? until $100000 @ ;
: emit ( c -- ) begin $100004 @ 2 and until $100000 ! ;
: led! ( n -- ) $100008 ! ;
: led@ ( -- n ) $100008 @ ;
: btn@ ( -- n ) $10000C @ 15 and ;
: sw@ ( -- n ) $10000C @ 4 rshift ;
: rgb! ( n -- ) $100010 ! ;
: rgb@ ( -- n ) $100010 @ ;
: ms@ ( -- n ) $100014 @ ;
: us@ ( -- n ) $100018 @ ;
: ms ( n -- ) ms@ + begin dup ms@ - 0< until drop ;

\ ---------------------------------------------------------------------------
\ Shield digital pins. Pin numbers are the shield labels: 0..13 = IO0..IO13,
\ 14..19 = A0..A5 used as digital pins, 26..41 = IO26..IO41, 42..47 = the
\ shield's SCL and SDA and the SPI header's MISO, MOSI, SCK and SS. Pin n is bit
\ n%16 of port n/16 at $100020+16*(n/16): +0 pin levels, +4 output latch, +8
\ direction (1 = output). Every pin is an input after reset.
\ ---------------------------------------------------------------------------

42 constant pin-scl   43 constant pin-sda   44 constant pin-miso
45 constant pin-mosi  46 constant pin-sck   47 constant pin-ss
: bset ( mask a -- ) dup @ rot or swap ! ;
: bclr ( mask a -- ) dup @ rot invert and swap ! ;
: pin ( n -- mask a )
  dup 0 20 within over 26 48 within or 0= if ."  bad pin" cr abort then
  dup 15 and 1 swap lshift swap 4 rshift 4 lshift $100020 + ;
: output ( n -- ) pin 8 + bset ;
: input ( n -- ) pin 8 + bclr ;
: high ( n -- ) pin 4 + bset ;
: low ( n -- ) pin 4 + bclr ;
: toggle ( n -- ) pin 4 + dup @ rot xor swap ! ;
: pin@ ( n -- f ) pin @ and 0<> ;
: pin! ( f n -- ) swap if high else low then ;

\ A pin given to a peripheral belongs to it until the peripheral lets it go: its
\ latch and direction no longer count. Owners: 1..4 PWM 0..3, 5 UART 0, 6 UART 1,
\ 7 SPI 0, 8 SPI 1, 9 I2C, 10 DDS.
create pin-owner 48 allot
: owner ( pin -- id ) dup pin 2drop pin-owner + c@ ;
\ (free) refuses a pin another owner has; the open words check every pin first,
\ so a refused one leaves nothing half claimed
: (free) ( pin id -- pin ) over owner ?dup if <> if ."  pin taken" cr abort then else drop then ;
: claim ( pin id -- ) 2dup (free) drop swap pin-owner + c! ;
: (claim) ( pin id -- pin ) over swap claim ;
: release ( id -- ) 48 0 do i pin-owner + c@ over = if 0 i pin-owner + c! then loop drop ;

\ ---------------------------------------------------------------------------
\ Durations and periods are double cells ( lo hi ) meaning lo + hi*65536, so
\ sources written for the 16-bit ZYNQ-FORTH, whose double cells have 16-bit
\ halves, keep working; with this Forth's own words hi is 0.
\ ---------------------------------------------------------------------------

: d>ticks ( d -- u )
  dup if
    over $FFFF u> over $FFFF u> or if ."  too long" cr abort then 16 lshift +
  else drop then ;

\ ---------------------------------------------------------------------------
\ PWM: four channels at $100100 + 16c, each on any shield pin. The period counts
\ 50 MHz clocks (32 bits), the duty is a fraction in 1/65536 (rtl/pwm.v).
\ ---------------------------------------------------------------------------

: pwm ( ch -- a ) dup 4 u< 0= if ."  bad channel" cr abort then 4 lshift $100100 + ;
: pwm-clocks ( ud ch -- ) pwm >r d>ticks dup $FFFF and r@ ! 16 rshift r> 4 + ! ;
: ud/u ( ud u -- ud' ) >r 0 r@ um/mod r> swap >r um/mod nip r> ;
: pwm-hz ( u ch -- )
  over 0= if ."  bad frequency" cr abort then >r 50000000 swap u/mod nip 0 r> pwm-clocks ;
: pwm-khz ( u ch -- )
  over 1 25001 within 0= if ."  bad frequency" cr abort then
  >r 50000 swap u/mod nip 0 r> pwm-clocks ;
: pwm-duty ( permille ch -- ) >r 0 max 1000 min 65535 * 1000 / r> pwm 8 + ! ;
: pwm-pin ( pin ch -- )
  dup pwm drop dup 1+ release >r r@ 1+ (claim) $8000 or r> pwm 12 + ! ;
: pwm-off ( ch -- ) dup pwm 12 + 0 swap ! 1+ release ;

\ ---------------------------------------------------------------------------
\ Serial interfaces at $100200 (rtl/uart.v, spi.v, i2c.v): every signal on any
\ pin. UART u = 0, 1 at $100200 + 16u: 8N1, 64-byte FIFOs. SPI s = 0, 1 at
\ $100220 + 32s: master, modes 0..3, 8/16/32 bits, up to 12.5 MHz; chip selects
\ are ordinary pins. I2C at $100260: master, open drain, clock stretching.
\ ---------------------------------------------------------------------------

: uart ( u -- a ) dup 2 u< 0= if ."  bad uart" cr abort then 4 lshift $100200 + ;
: uart-open ( baud tx rx u -- )
  dup uart drop dup >r 5 + release
  r@ 5 + (free) swap r@ 5 + (free) swap
  r@ 5 + (claim) 8 lshift swap r@ 5 + (claim) or $8000 or
  swap dup 0= if ."  bad baud" cr abort then 50000000 swap u/mod nip
  r@ uart 8 + ! r> uart 12 + ! ;
: uart-close ( u -- ) dup uart 12 + 0 swap ! 5 + release ;
: uart-emit ( c u -- ) uart begin dup 4 + @ 2 and until ! ;
: uart-key? ( u -- f ) uart 4 + @ 1 and 0<> ;
: uart-key ( u -- c ) uart begin dup 4 + @ 1 and until @ $FF and ;
: uart-type ( a n u -- ) >r begin dup while over c@ r@ uart-emit 1 /string repeat 2drop r> drop ;
\ bit 2 transmitter idle, bit 3 a received byte was lost, bit 4 framing error;
\ reading clears bits 3 and 4
: uart-status ( u -- bits ) uart 4 + dup @ $1C and 0 rot ! ;

: spi ( s -- a ) dup 2 u< 0= if ."  bad spi" cr abort then 5 lshift $100220 + ;
variable cid
: spi-open ( sck mosi miso s -- )
  dup spi drop dup >r 7 + dup cid ! release
  cid @ (free) >r cid @ (free) >r cid @ (free) r> r>
  cid @ (claim) 16 lshift swap cid @ (claim) 8 lshift or swap cid @ (claim) or
  $80000000 or r> spi 16 + ! ;
: spi-close ( s -- ) dup spi 16 + 0 swap ! 7 + release ;
: spi-hz ( hz s -- )
  >r dup 0= if ."  bad frequency" cr abort then
  25000000 swap u/mod swap if 1+ then 2 max r> spi 12 + ! ;
: spi-mode ( mode s -- ) spi 8 + dup @ 3 invert and rot 3 and or swap ! ;
: spi-lsb ( f s -- ) spi 8 + dup @ 4 invert and rot if 4 or then swap ! ;
: spi-bits ( n s -- )
  >r dup 8 = if drop 0 else 16 = if $10 else $20 then then
  r> spi 8 + dup @ $30 invert and rot or swap ! ;
: spi-xfer ( out s -- in ) spi tuck ! begin dup 4 + @ 1 and 0= until @ ;
: spi-write ( a n s -- ) >r begin dup while over c@ r@ spi-xfer drop 1 /string repeat 2drop r> drop ;
: spi-read ( a n s -- )
  >r begin dup while 0 r@ spi-xfer >r over r> swap c! 1 /string repeat 2drop r> drop ;

: (i2c) ( cmd -- status )
  $100260 ! begin $100260 @ dup 0< while drop repeat
  dup $200 and if ."  i2c timeout" cr abort then ;
: i2c-open-pins ( hz scl sda -- )
  9 release 9 (free) swap 9 (free) swap
  9 (claim) 8 lshift swap 9 (claim) or $8000 or >r
  dup 0= if ."  bad frequency" cr abort then
  12500000 swap u/mod swap if 1+ then 2 + $100264 ! r> $100268 ! ;
: i2c-open ( hz -- ) pin-scl pin-sda i2c-open-pins ;
: i2c-close ( -- ) 0 $100268 ! 9 release ;
: i2c-start ( -- ) $100 (i2c) drop ;
: i2c-stop ( -- ) $200 (i2c) drop ;
: i2c-write ( b -- ack? ) $FF and $300 or (i2c) $100 and 0<> ;
: i2c-read ( ack? -- b ) if $400 else $500 then (i2c) $FF and ;
\ start (or a repeated start), then the address byte: 7-bit address, rw 1 = read
: i2c-addr ( addr rw -- ack? ) i2c-start swap 2* or i2c-write ;
: (ack?) ( f -- ) 0= if i2c-stop ."  no ack" cr abort then ;
: i2c! ( b reg addr -- ) 0 i2c-addr (ack?) i2c-write (ack?) i2c-write (ack?) i2c-stop ;
: i2c@ ( reg addr -- b )
  dup >r 0 i2c-addr (ack?) i2c-write (ack?) r> 1 i2c-addr (ack?) 0 i2c-read i2c-stop ;
: i2c-probe ( addr -- f ) 0 i2c-addr i2c-stop ;
: i2c-scan ( -- )
  base @ >r hex 120 8 do i i2c-probe if i . then loop r> base ! cr ;

\ ---------------------------------------------------------------------------
\ DDS at $100280 (rtl/dds.v): a square wave on any pin from a 32-bit phase
\ accumulator at 200 MHz, f in steps of 0.047 Hz, edges on the 5 ns grid.
\ Tone generator at $1002A0 (rtl/tone.v): sine, square, triangle or sawtooth on
\ the board's audio jack, steps of 0.012 Hz, volume ramps without clicks.
\ ---------------------------------------------------------------------------

: dds-sync ( -- ) begin $100284 @ 0< 0= until ;
: dds-hz ( F: hz -- ) 21.47483648e f* fround f>u $100280 ! dds-sync ;
: dds-pin ( pin -- ) 10 release 10 (claim) 8 lshift 1 or $100284 ! dds-sync ;
: dds-off ( -- ) 0 $100284 ! 10 release dds-sync ;

0 constant sine   1 constant square   2 constant triangle   3 constant sawtooth
: tone ( F: hz -- ) 85.89934592e f* fround f>u $1002A0 ! $1002A4 @ 1 or $1002A4 ! ;
: tone-off ( -- ) $1002A4 @ -2 and $1002A4 ! ;
: wave ( n -- ) 3 and 2* $1002A4 @ 1 and or $1002A4 ! ;
: volume ( percent -- ) 0 max 100 min 65535 * 100 / $1002A8 ! ;
: beep ( ms -- ) ( F: hz -- ) tone ms tone-off ;

\ ---------------------------------------------------------------------------
\ Pattern generator: 16 channels, 0..7 on Pmod JA and 8..15 on JB, played in
\ ticks of 5 ns from its own clock (rtl/patgen.v, docs/PatternGenerator.md).
\ Registers at $100180 + 4r. Durations are double cells in ticks (see d>ticks).
\ A step stores its levels, duration and what happens after it; the generator
\ can only be loaded while stopped.
\ ---------------------------------------------------------------------------

: ns ( n -- d ) 5 u/mod nip 0 ;
: (dur) ( d -- d ) dup if ."  too long" cr abort then ;
\ from 2^32 ticks (21.47 s) on, a duration is refused here: d>ticks would read it
\ as a 16-bit-style double
: us ( n -- d ) 200 um* (dur) ;
: d2* ( d -- d' ) swap dup 0< >r 2* swap 2* r> if 1+ then ;
: msec ( n -- d ) 200000 um* (dur) ;
: pg-sync ( -- ) begin $100180 @ $40 and 0= until ;
: pg-status ( -- u ) pg-sync $100180 @ ;
: pg-pc ( -- step ) $100184 @ ;
: pg-out@ ( -- levels ) $100188 @ ;
: pg-at ( step -- ) $100184 ! ;
: (pg) ( out d op count -- )
  pg-status 1 and if ."  pattern running" cr abort then
  >r >r d>ticks dup 16 rshift $100190 ! $FFFF and $10018C ! $100188 !
  r> $100194 ! r> $100198 ! ;
: pg-step ( out d -- ) 0 0 (pg) ;
: pg-loop ( out d target count -- ) >r $FFF and $1000 or r> (pg) ;
: pg-jump ( out d target -- ) $FFF and $2000 or 0 (pg) ;
: pg-wait ( out d -- ) $3000 0 (pg) ;
: pg-end ( out -- ) 0 0 $4000 0 (pg) ;
: pg-start ( -- ) 1 $100180 ! pg-sync ;
: pg-stop ( -- ) 2 $100180 ! pg-sync ;
: pg-trig ( -- ) 4 $100180 ! pg-sync ;
: pg-enable ( mask -- ) $10019C ! pg-sync ;
: pg-idle ( levels -- ) $1001A0 ! pg-sync ;
\ source: pin 0..41, 48..51 = BTN0..BTN3, 63 = software only; edge: 1 rising,
\ 2 falling, 3 both
: pg-trigger ( source edge -- ) 8 lshift or $1001A4 ! pg-sync ;

\ ---------------------------------------------------------------------------
\ Analog inputs (XADC). Its status registers 0..31 appear at $100080 + 4r;
\ results are 12 bits in bits 15..4. Channels 0..5 = A0..A5 (0..3.32 V through
\ a divider), 6..8 = the pairs A6/A7, A8/A9, A10/A11 (0..1 V, + minus -).
\ ---------------------------------------------------------------------------

: xadc@ ( reg -- u ) 31 and 2 lshift $100080 + @ 4 rshift ;
create vaux 1 c, 9 c, 6 c, 15 c, 5 c, 13 c, 12 c, 0 c, 8 c,
: adc@ ( ch -- u )
  dup 9 u< 0= if ."  bad channel" cr abort then vaux + c@ 16 + xadc@ ;
: mv@ ( ch -- mv ) dup adc@ swap 6 < if 3320 else 1000 then 4096 */ ;
: supply@ ( reg -- mv ) xadc@ 3000 4096 */ ;
: temp@ ( -- n ) 0 xadc@ 5040 4096 */ 2731 - ;
: .temp ( -- ) temp@ dup 0< if 45 emit negate then 10 u/mod (u.) 46 emit (u.) ."  C " ;
: volts@ ( ch -- ) ( F: -- v )
  dup adc@ s>f 4096e f/ 6 < if 3.32e else 1e then f* ;
: ftemp@ ( F: -- celsius ) 0 xadc@ s>f 503.975e f* 4096e f/ 273.15e f- ;

\ ---------------------------------------------------------------------------
\ Output
\ ---------------------------------------------------------------------------

: cr 13 emit 10 emit ;
: space 32 emit ;
: spaces ( n -- ) begin dup 0> while space 1- repeat drop ;
: zeros ( n -- ) begin dup 0> while 48 emit 1- repeat drop ;
: type ( a n -- ) begin dup while swap dup c@ emit 1+ swap 1- repeat 2drop ;
: (.") ( -- ) r> dup c@ swap 1+ swap 2dup type + aligned >r ;
: digit ( u -- c ) dup 9 > if 7 + then 48 + ;
: (u.) ( u -- ) base @ u/mod ?dup if recurse then digit emit ;
: u. ( u -- ) (u.) space ;
: . ( n -- ) dup 0< if 45 emit negate then u. ;
\ .S parks the stack in SBUF (not on the 32-deep return stack), prints it
\ bottom first and pushes it back
create sbuf 128 allot
variable sn
: .s ( -- )
  depth dup sn ! 60 emit (u.) 62 emit space
  sn @ begin dup while 1- swap over cells sbuf + ! repeat drop
  sn @ 0 begin 2dup > while dup cells sbuf + @ dup . -rot 1+ repeat 2drop ;
: ? ( a -- ) @ . ;

\ ---------------------------------------------------------------------------
\ Parsing
\ ---------------------------------------------------------------------------

: more? ( -- f ) >in @ #tib @ < ;
: in-char ( -- c ) tib >in @ + c@ ;
: parse-name ( -- a n )
  begin more? if in-char 33 < else 0 then while 1 >in +! repeat
  tib >in @ +
  begin more? if in-char 32 > else 0 then while 1 >in +! repeat
  tib >in @ + over - ;
: parse ( c -- a n )
  >r more? if in-char 32 = if 1 >in +! then then
  tib >in @ +
  begin more? if in-char r@ <> else 0 then while 1 >in +! repeat
  r> drop
  tib >in @ + over -
  more? if 1 >in +! then ;

\ ---------------------------------------------------------------------------
\ Dictionary search
\ header: link (cell), count byte (bits 4..0 length, $80 immediate, $40 hidden,
\ $20 inline), name, padding to a cell boundary
\ ---------------------------------------------------------------------------

: upper ( c -- c' ) dup 97 < invert over 122 > invert and if 32 - then ;
: same? ( a1 a2 n -- f )
  begin dup while
    >r over c@ upper over c@ upper <> if r> drop 2drop 0 exit then
    1+ swap 1+ swap r> 1-
  repeat drop 2drop -1 ;
: name>count ( h -- a n ) 4 + dup 1+ swap c@ 31 and ;
: name>xt ( h -- xt ) 4 + dup c@ 31 and + 1+ aligned ;
: match? ( h -- f )
  dup 4 + c@ dup 64 and if 2drop 0 exit then
  31 and 'n @ = if 5 + 'a @ 'n @ same? exit then
  drop 0 ;
: find-name ( a n -- h | 0 )
  'n ! 'a ! latest @
  begin dup while dup match? if exit then @ repeat ;

\ ---------------------------------------------------------------------------
\ Numbers: optional - then $ (hex) prefix, digits in BASE
\ ---------------------------------------------------------------------------

: digit? ( c -- n f )
  upper 48 - dup 9 > if 7 - dup 10 < if drop -1 then then
  dup base @ u< ;
: >number ( acc a n -- acc' a' n' )
  begin
    dup 0= if exit then
    over c@ digit? 0= if drop exit then
    >r rot base @ * r> + -rot 1 /string
  again ;
: number? ( a n -- x f )
  base @ >r
  over c@ 45 = over 1 > and dup >r if 1 /string then
  over c@ 36 = over 1 > and if 16 base ! 1 /string then
  0 -rot >number nip 0=
  r> if swap negate swap then
  r> base ! ;

\ ---------------------------------------------------------------------------
\ Floating point: IEEE single precision in hardware (rtl/hf32_mcu.v), round to
\ nearest even, subnormals count as zero. Float literals: digits with a point
\ or an exponent, like 1.5 -2e3 1e .5e-2 (read in decimal base only).
\ ---------------------------------------------------------------------------

: frot ( F: r1 r2 r3 -- r2 r3 r1 ) f>bits fswap bits>f fswap ;
: fnip ( F: r1 r2 -- r2 ) fswap fdrop ;
: f> ( F: r1 r2 -- ) ( -- f ) fswap f< ;
: f0> ( F: r -- ) ( -- f ) fnegate f0< ;
: fmin ( F: r1 r2 -- r3 ) fover fover f< if fdrop else fnip then ;
: fmax ( F: r1 r2 -- r3 ) fover fover f< if fnip else fdrop then ;
: (inf) ( F: -- inf ) $7F800000 bits>f ;
: (nan) ( F: -- nan ) $7FC00000 bits>f ;
: fnan? ( F: r -- r ) ( -- f ) fdup fdup f= 0= ;
: finf? ( F: r -- r ) ( -- f ) fdup fabs f>bits $7F800000 = ;
: floor ( F: r -- r' ) fdup ftrunc fswap fover f< if 1e f- then ;
\ round half to even: below 2^23, adding and taking away 2^23 rounds in the FPU
: fround ( F: r -- r' )
  fdup fabs 8388608e f< if
    fdup f0< fabs 8388608e f+ 8388608e f- if fnegate then
  then ;
: u>f ( u -- ) ( F: -- r ) dup 0< if dup 1 rshift swap 1 and or s>f fdup f+ else s>f then ;
: f>u ( F: r -- ) ( -- u )
  fdup f0< if fdrop 0 exit then
  fdup 2147483648e f< if f>s else 2147483648e f- f>s $80000000 or then ;
: d>f ( d -- ) ( F: -- r )
  dup 0< >r r@ if dnegate then u>f 4294967296e f* u>f f+ r> if fnegate then ;
: f>d ( F: r -- ) ( -- d )
  fdup f0< >r fabs
  fdup 4294967296e f< if f>u 0
  else fdup 4294967296e f/ ftrunc fdup f>u 4294967296e f* f- f>u swap then
  r> if dnegate then ;
: float+ ( a -- a+4 ) 4 + ;
: floats ( n -- n*4 ) 2 lshift ;
: falign ( -- ) align ;
: faligned ( a -- a' ) aligned ;
: sfloat+ ( a -- a+4 ) 4 + ;
: sfloats ( n -- n*4 ) 2 lshift ;
: sfalign ( -- ) align ;
: sfaligned ( a -- a' ) aligned ;
: f, ( F: r -- ) f>bits , ;

\ powers of ten 10^0 .. 10^10, all exact in single precision
create tens 1e f, 10e f, 100e f, 1000e f, 10000e f, 100000e f, 1000000e f,
  10000000e f, 100000000e f, 1000000000e f, 10000000000e f,
: 10^ ( n -- ) ( F: -- 10^n ) cells tens + f@ ;
\ Exact scaling for the conversions: a product a*b of two singles is p + err
\ exactly (Dekker's split, a 12-bit high half), so x*10^s for |s| <= 10 needs
\ only the final rounding. Conversions are correctly rounded (up to exact ties)
\ for 1e-10 <= |r| < 1e10; outside, one step of 10^10 scaling rounds first.
fvariable (ta)   fvariable (ah)   fvariable (al)   fvariable (bh)   fvariable (bl)
fvariable (tp)   fvariable (te)   fvariable (td)   fvariable (tq)
fvariable (rx)   fvariable (tl)
: (split) ( F: a -- hi lo )
  fdup fabs 1e30 f> if
    268435456e f/ (split) 268435456e f* fswap 268435456e f* fswap exit
  then
  fdup (ta) f! 4097e f* fdup (ta) f@ f- f- fdup (ta) f@ fswap f- ;
\ scaling by 2^-64 or 2^64 keeps the partial products of a large or tiny
\ operand from overflowing or flushing to zero
: (2prod) ( F: a b -- p err )
  fover fabs fover fabs f< if fswap then
  fdup f0= if fdrop fdrop 0e 0e exit then
  fover fabs 1e20 f> if
    fswap 5.421010862427522e-20 f* fswap (2prod)
    18446744073709551616e f* fswap 18446744073709551616e f* fswap exit
  then
  fdup fabs 1e-20 f< if
    18446744073709551616e f* (2prod)
    5.421010862427522e-20 f* fswap 5.421010862427522e-20 f* fswap exit
  then
  (split) (bl) f! (bh) f! (split) (al) f! (ah) f!
  (ah) f@ (al) f@ f+ (bh) f@ (bl) f@ f+ f* fdup (tp) f!
  (ah) f@ (bh) f@ f* (tp) f@ f- (ah) f@ (bl) f@ f* f+ (al) f@ (bh) f@ f* f+ (al) f@ (bl) f@ f* f+ ;
\ (rx) + (tl) := (rx + tl) / 10^n as quotient + remainder/10^n, 0 <= n <= 10
: (fdiv10^) ( n -- )
  10^ fdup (td) f! (rx) f@ fswap f/ fdup (tq) f!
  (td) f@ (2prod) (te) f! (rx) f@ fswap f- (te) f@ f- (tl) f@ f+ (td) f@ f/
  (tl) f! (tq) f@ (rx) f! ;
\ (rx) + (tl) := (rx + tl) * 10^n as product + error, 0 <= n <= 10
: (fmul10^) ( n -- ) 10^ fdup (td) f! (rx) f@ (2prod) (tl) f@ (td) f@ f* f+ (tl) f! (rx) f! ;
\ (rx + tl) * 10^s as p + err, -20 <= s <= 20
: (scaled) ( s -- ) ( F: -- p err )
  dup 0< if
    negate dup 10 > if 10 - 10 (fdiv10^) then (fdiv10^) (rx) f@ (tl) f@
  else dup 10 > if
    10 - (rx) f@ 10000000000e (2prod) (tl) f@ 10000000000e f* f+
    dup 10^ f* (te) f! 10^ (2prod) (te) f@ f+
  else
    10^ fdup (td) f! (rx) f@ (2prod) (tl) f@ (td) f@ f* f+
  then then ;

\ >FLOAT: [sign] digits [. digits] [E|e [sign] digits], at least one digit;
\ up to 9 significant digits are used
variable (fm)   variable (fx)   variable (fe)   variable (fany)   variable (fneg)
: (fdigit) ( c -- accepted? )
  48 - (fm) @ 100000000 u< if (fm) @ 10 * + (fm) ! -1 else drop 0 then -1 (fany) ! ;
: (digits?) ( a n -- a n f ) dup if over c@ 48 58 within else 0 then ;
: (fexp) ( a n -- a' n' )
  0 (fe) ! dup 0= if exit then
  over c@ dup 45 = swap 43 = or if over c@ 45 = >r 1 /string else 0 >r then
  begin (digits?) while over c@ 48 - (fe) @ 10 * + 999 min (fe) ! 1 /string repeat
  r> if (fe) @ negate (fe) ! then ;
\ n * 10^e, n < 10^9
\ (small results are built 2^64 times larger, so no intermediate is tiny)
: (fbuild) ( n e -- ) ( F: -- r )
  over 0= if 2drop 0e exit then
  dup 38 > if 2drop (inf) exit then
  dup -55 < if 2drop 0e exit then
  swap dup s>f fdup f>s - s>f (tl) f! (rx) f!
  dup -20 < dup >r if
    (rx) f@ 18446744073709551616e f* (rx) f! (tl) f@ 18446744073709551616e f* (tl) f!
  then
  begin dup 20 > while 10 (fmul10^) 10 - repeat
  begin dup -20 < while 10 (fdiv10^) 10 + repeat
  dup >r (scaled) fswap finf? if
    \ the product alone overflowed: once more at half the value
    fdrop fdrop (rx) f@ 0.5e f* (rx) f! (tl) f@ 0.5e f* (tl) f! r@ (scaled) f+ 2e f*
  else f+ then
  r> drop r> if 5.421010862427522e-20 f* then ;
: >float ( a n -- true | false ) ( F: -- r | )
  0 (fm) ! 0 (fx) ! 0 (fany) ! 0 (fneg) ! 0 (fe) !
  dup 0= if 2drop 0 exit then
  over c@ dup 45 = swap 43 = or if over c@ 45 = (fneg) ! 1 /string then
  begin (digits?) while over c@ (fdigit) 0= if 1 (fx) +! then 1 /string repeat
  dup if over c@ 46 = if
    1 /string
    begin (digits?) while over c@ (fdigit) if -1 (fx) +! then 1 /string repeat
  then then
  (fany) @ 0= if 2drop 0 exit then
  dup if over c@ upper 69 = if 1 /string (fexp) then then
  nip if 0 exit then
  (fm) @ (fx) @ (fe) @ + (fbuild) (fneg) @ if fnegate then -1 ;

\ REPRESENT and the float output words. PRECISION significant digits (1..9).
variable (fprec)
variable (rep-a)   variable (rep-u)   variable (rk)   variable (rkk)
create (fbuf) 12 allot
: precision ( -- u ) (fprec) @ ;
: set-precision ( u -- ) 1 max 9 min (fprec) ! ;
\ largest j in 0..9 with 10^j <= x
: (decade) ( F: x -- x ) ( -- j )
  0 begin dup 9 < if dup 1+ 10^ fover f> 0= else 0 then while 1+ repeat ;
\ smallest j in 1..10 with x*10^j >= 1
: (updecade) ( F: x -- x ) ( -- j )
  1 begin dup 10 < if fdup dup 10^ f* 1e f< else 0 then while 1+ repeat ;
\ p + err rounded to the nearest integer, ties to even
: (round2) ( F: p err -- ) ( -- m )
  (te) f! fdup fround fdup f>s >r f- (te) f@ f+
  fdup fround fdup f>s >r f-
  r> r> +
  fdup 0.5e f= if dup 1 and if 1+ then then
  fdup -0.5e f= if dup 1 and if 1- then then
  fdrop ;
: (ipow) ( u -- n ) 10^ f>s ;
\ the significand of (rx) * 10^(precision-1-k) as an integer
: (digits) ( -- m ) (rep-u) @ 1- (rk) @ - (scaled) (round2) ;
: represent ( a u -- n flag1 flag2 ) ( F: r -- )
  9 min 1 max (rep-u) ! (rep-a) !
  fdup f0< >r fabs
  fnan? finf? or if fdrop 0 r> 0 exit then
  fdup f0= if fdrop (rep-a) @ (rep-u) @ 48 fill 1 r> -1 exit then
  (rx) f! 0e (tl) f!
  0 begin (rx) f@ 100000000000000000000e f< 0= while 10 (fdiv10^) 10 + repeat
  begin (rx) f@ 1e-10 f< while 10 (fmul10^) 10 - repeat (rkk) !
  (rx) f@ fdup 10000000000e f< 0= if 10000000000e f/ (decade) 10 +
  else fdup 1e f< if (updecade) negate else (decade) then then
  fdrop (rk) !
  \ the estimate of k may be one off above 1e10 or below 1
  begin (digits)
    dup (rep-u) @ 1- (ipow) < if drop -1 (rk) +! 0
    else dup (rep-u) @ (ipow) > if drop 1 (rk) +! 0 else -1 then then
  until
  dup (rep-u) @ (ipow) = if 10 / 1 (rk) +! then
  (rep-u) @ begin dup while 1- >r 10 u/mod swap 48 + (rep-a) @ r@ + c! r> repeat
  2drop (rk) @ (rkk) @ + 1+ r> -1 ;
\ NaN and infinities print as words; true if r was one of them
\ the exponent of FS. F. FE., in decimal whatever BASE is
: (.exp) ( n -- ) 69 emit base @ >r decimal . r> base ! ;
: (fspecial) ( F: r -- r | ) ( -- f )
  fnan? if fdrop ." NaN " -1 exit then
  finf? if f0< if 45 emit then ." Inf " -1 exit then 0 ;
\ significant digits in (fbuf) without trailing zeros
: (fsig) ( -- s )
  precision begin dup 1 > if dup 1- (fbuf) + c@ 48 = else 0 then while 1- repeat ;
: (fixed) ( n s -- )
  over 0> 0= if 48 emit 46 emit swap negate zeros (fbuf) swap type exit then
  2dup < 0= if (fbuf) over type - zeros 46 emit exit then
  over (fbuf) swap type 46 emit over - swap (fbuf) + swap type ;
: fs. ( F: r -- )
  (fspecial) if exit then (fbuf) precision represent drop if 45 emit then
  (fbuf) c@ emit 46 emit (fbuf) 1+ precision 1- type 1- (.exp) ;
: f. ( F: r -- )
  (fspecial) if exit then (fbuf) precision represent drop if 45 emit then
  (fsig) over dup -6 < swap 9 > or if
    (fbuf) c@ emit 46 emit (fbuf) 1+ swap 1- type 1- (.exp)
  else (fixed) space then ;
: fe. ( F: r -- )
  (fspecial) if exit then (fbuf) precision represent drop if 45 emit then
  1- dup 3 mod dup 0< if 3 + then                       ( e m3 )
  dup 1+ dup precision min (fbuf) swap type precision - zeros
  46 emit dup 1+ precision over - 0 max swap (fbuf) + swap type
  - (.exp) ;
\ the float stack, bottom first, through SBUF like .S
: f.s ( -- )
  fdepth dup sn ! 60 emit (u.) 62 emit space
  sn @ begin dup while 1- f>bits over cells sbuf + ! repeat drop
  sn @ 0 begin 2dup > while dup cells sbuf + @ bits>f fdup f. 1+ repeat 2drop ;

\ ---------------------------------------------------------------------------
\ Elementary functions (polynomials after Cephes' single-precision library):
\ about 1e-7 relative error; the trigonometric functions reduce the argument
\ with pi/2 in three parts, accurate for |x| up to about 10000.
\ ---------------------------------------------------------------------------

3.14159265e fconstant pi
fvariable (fz)   fvariable (fk)   fvariable (fy0)
: 2^n ( n -- ) ( F: -- 2^n ) 127 + 23 lshift bits>f ;
\ x = k*pi/2 + r with |r| <= pi/4, q = k mod 4
: (reduce) ( F: x -- r ) ( -- q )
  fdup 0.636619772e f* fround fdup (fk) f! f>s 3 and
  (fk) f@ 1.5703125e f* f- (fk) f@ 4.837512969970703125e-4 f* f-
  (fk) f@ 7.54978995489188216e-8 f* f- ;
: (sin) ( F: r -- s )
  fdup fdup f* (fz) f!
  (fz) f@ -1.9515295891e-4 f* 8.3321608736e-3 f+ (fz) f@ f* -1.6666654611e-1 f+
  (fz) f@ f* fover f* f+ ;
: (cos) ( F: r -- c )
  fdup f* fdup (fz) f!
  2.443315711809948e-5 f* -1.388731625493765e-3 f+ (fz) f@ f* 4.166664568298827e-2 f+
  (fz) f@ f* (fz) f@ f* 0.5e (fz) f@ f* f- 1e f+ ;
: fsincos ( F: x -- sin cos )
  (reduce) >r fdup (sin) fswap (cos)
  r@ 1 and if fswap then
  r@ 1- 2 u< if fnegate then
  r> 2 and if fswap fnegate fswap then ;
: fsin ( F: x -- sin ) fsincos fdrop ;
: fcos ( F: x -- cos ) fsincos fnip ;
: ftan ( F: x -- tan ) fsincos f/ ;
: fatan ( F: x -- r )
  fdup f0< >r fabs
  fdup 2.414213562373095e f> if -1e fswap f/ 1.5707963267948966e
  else fdup 0.414213562373095e f> if fdup 1e f- fswap 1e f+ f/ 0.7853981633974483e
  else 0e then then (fy0) f!
  fdup fdup f* (fz) f!
  (fz) f@ 8.05374449538e-2 f* -1.38776856032e-1 f+ (fz) f@ f* 1.99777106478e-1 f+
  (fz) f@ f* -3.33329491539e-1 f+ (fz) f@ f* fover f* f+
  (fy0) f@ f+ r> if fnegate then ;
: fatan2 ( F: y x -- r )
  fdup f0= if
    fdrop fdup f0= if exit then
    f0< if -1.5707963267948966e else 1.5707963267948966e then exit
  then
  fdup f0< if
    fover f0< >r f/ fatan r> if 3.141592653589793e f- else 3.141592653589793e f+ then
  else f/ fatan then ;
: fasin ( F: x -- r ) fdup 1e fswap f- fover 1e f+ f* fsqrt fatan2 ;
: facos ( F: x -- r ) fdup 1e fswap f- fover 1e f+ f* fsqrt fswap fatan2 ;
\ times 2^n for -127 <= n <= 128
: (f2^n) ( n -- ) ( F: r -- r' )
  dup 127 > if 1- 2e f* then dup -126 < if 1+ 0.5e f* then 2^n f* ;
: fexp ( F: x -- e^x )
  fnan? if exit then
  fdup 88.72283905e f> if fdrop (inf) exit then
  fdup -87.33654475e f< if fdrop 0e exit then
  fdup 1.4426950408889634e f* fround fdup f>s >r
  fswap fover 0.693359375e f* f- fswap -2.12194440e-4 f* f-
  fdup fdup f* (fz) f!
  fdup 1.9875691500e-4 f* 1.3981999507e-3 f+ fover f* 8.3334519073e-3 f+
  fover f* 4.1665795894e-2 f+ fover f* 1.6666665459e-1 f+ fover f* 5.0000001201e-1 f+
  (fz) f@ f* f+ 1e f+
  r> (f2^n) ;
: fln ( F: x -- ln x )
  fnan? if exit then
  fdup f0= if fdrop (inf) fnegate exit then
  fdup f0< if fdrop (nan) exit then
  finf? if exit then
  f>bits dup 23 rshift 255 and 126 - >r $807FFFFF and $3F000000 or bits>f
  fdup 0.70710678118654752e f< if r> 1- >r fdup f+ 1e f- else 1e f- then
  fdup fdup f* (fz) f!
  fdup 7.0376836292e-2 f* -1.1514610310e-1 f+ fover f* 1.1676998740e-1 f+
  fover f* -1.2420140846e-1 f+ fover f* 1.4249322787e-1 f+ fover f* -1.6668057665e-1 f+
  fover f* 2.0000714765e-1 f+ fover f* -2.4999993993e-1 f+ fover f* 3.3333331174e-1 f+
  fover f* (fz) f@ f*
  r@ s>f -2.12194440e-4 f* f+ (fz) f@ 0.5e f* f- f+
  r> s>f 0.693359375e f* f+ ;
: flog ( F: x -- log10 x ) fln 0.4342944819032518e f* ;
: falog ( F: x -- 10^x ) 2.302585092994046e f* fexp ;
\ ln(1+x) and e^x-1 accurate near 0 (Kahan): the rounding of 1+x or e^x cancels
: flnp1 ( F: x -- ln[1+x] )
  fdup 1e f+ fdup 1e f= if fdrop exit then
  fdup fln fswap 1e f- f/ f* ;
: fexpm1 ( F: x -- e^x-1 )
  fdup fexp fdup 1e f= if fdrop exit then
  fdup 1e f- fdup -1e f= if fnip fnip exit then
  fswap fln f/ f* ;
: (f**) ( F: r1 r2 -- r1^r2 ) fswap fln f* fexp ;
: f** ( F: r1 r2 -- r3 )
  fdup f0= if fdrop fdrop 1e exit then
  fover f0= if fnip f0< if (inf) else 0e then exit then
  fover f0< if
    fdup fdup ftrunc f= 0= if fdrop fdrop (nan) exit then
    fdup 2e f/ fdup ftrunc f= 0= >r
    fswap fabs fswap (f**) r> if fnegate then
  else (f**) then ;
: fsinh ( F: x -- r )
  fdup f0< >r fabs
  fdup 1e f> if fexp fdup 1e fswap f/ f- 0.5e f*
  else
    fdup fdup f* (fz) f!
    (fz) f@ 2.03721912945e-4 f* 8.33028376239e-3 f+ (fz) f@ f* 1.66667160211e-1 f+
    (fz) f@ f* fover f* f+
  then r> if fnegate then ;
: fcosh ( F: x -- r ) fabs fexp fdup 1e fswap f/ f+ 0.5e f* ;
: ftanh ( F: x -- r )
  fdup f0< >r fabs
  fdup 0.625e f> if fdup f+ fexp 1e f+ 2e fswap f/ 1e fswap f-
  else
    fdup fdup f* (fz) f!
    (fz) f@ -5.70498872745e-3 f* 2.06390887954e-2 f+ (fz) f@ f* -5.37397155531e-2 f+
    (fz) f@ f* 1.33314422036e-1 f+ (fz) f@ f* -3.33332819422e-1 f+ (fz) f@ f* fover f* f+
  then r> if fnegate then ;

\ ---------------------------------------------------------------------------
\ Compiler
\ ---------------------------------------------------------------------------

: compile-call ( xt -- ) 2 rshift $40000000 or , ;
: inline, ( xt -- ) begin dup @ dup [op] exit <> while , 4 + repeat 2drop ;
: compile, ( xt -- ) compile-call ;
: literal ( n -- )
  dup 0< if invert $80000000 or , [op] invert , else $80000000 or , then ; immediate
: fliteral ( F: r -- ) f>bits literal ['] bits>f inline, ; immediate
: cmove ( src dst n -- )
  begin dup while >r over c@ over c! 1+ swap 1+ swap r> 1- repeat drop 2drop ;
: header ( a n -- )
  align here >r
  latest @ ,
  dup c,
  here swap dup allot cmove
  align
  r> latest ! ;
: flags! ( mask -- ) latest @ 4 + dup c@ rot or swap c! ;
: immediate $80 flags! ;
: hide $40 flags! ;
: reveal latest @ 4 + dup c@ $BF and swap c! ;
: [ 0 state ! ; immediate
: ] -1 state ! ;
: : parse-name header hide ] ;
: ; [op] exit , reveal 0 state ! ; immediate
: create parse-name header here 8 + literal [op] exit , ;
: variable create 0 , ;
: fvariable create 0 , ;
: constant ( n -- ) parse-name header literal [op] exit , ;
: fconstant ( F: r -- ) parse-name header fliteral [op] exit , ;
: ' ( -- xt | 0 ) parse-name find-name dup if name>xt then ;
: ['] ' literal ; immediate
: recurse latest @ name>xt compile-call ; immediate
: ( 41 parse 2drop ; immediate
: \ #tib @ >in ! ; immediate
: ." ['] (.") compile-call 34 parse dup c, here swap dup allot cmove align ; immediate
: .( 41 parse type ; immediate

\ Control structures. Branch placeholders carry their opcode ($20000000
\ 0branch, $0 jump); >resolve ORs in the target cell address.
: >resolve ( orig -- ) dup @ here 2 rshift or swap ! ;
: if here $20000000 , ; immediate
: else here 0 , swap >resolve ; immediate
: then >resolve ; immediate
: begin here ; immediate
: until 2 rshift $20000000 or , ; immediate
: again 2 rshift , ; immediate
: while here $20000000 , swap ; immediate
: repeat 2 rshift , >resolve ; immediate
: do ['] swap inline, ['] >r inline, ['] >r inline, here ; immediate
: loop ['] (loop) compile-call 2 rshift $20000000 or , ['] unloop inline, ; immediate
: +loop ['] (+loop) compile-call 2 rshift $20000000 or , ['] unloop inline, ; immediate

\ ---------------------------------------------------------------------------
\ Interpreter
\ ---------------------------------------------------------------------------

: words ( -- )
  latest @ begin dup while dup name>count type space @ repeat drop cr ;

: abort ( -- ) begin depth while drop repeat begin fdepth while fdrop repeat quit ;

\ The stacks have 32 entries and wrap silently. Looking up a word needs up to
\ 9 more data cells (find-name -> same? -> upper), so more than 20 user items
\ count as overflow; a wrapped-around depth (above 28) means underflow.
: ?stack ( -- )
  depth 28 > if ."  stack underflow" cr abort then
  depth 20 > if ."  stack overflow" cr abort then
  fdepth 28 > if ."  float stack underflow" cr abort then
  fdepth 20 > if ."  float stack overflow" cr abort then ;

\ a float literal is read in decimal base only
: float? ( a n -- f ) ( F: -- r | ) base @ 10 = if >float else 2drop 0 then ;

: interpret-word ( a n -- )
  2dup find-name ?dup if
    nip nip dup name>xt swap 4 + c@      ( xt count )
    state @ if
      dup $80 and if drop execute
      else $20 and if inline, else compile, then then
    else drop execute then
  else
    2dup number? if
      nip nip state @ if literal then
    else
      drop 2dup float? if
        2drop state @ if fliteral then
      else
        type ."  ?" cr abort
      then
    then
  then ;

: interpret ( -- )
  begin parse-name dup while interpret-word ?stack repeat 2drop ;

: accept-line ( -- )
  0 #tib ! 0 >in !
  begin key dup 13 = over 10 = or 0= while
    dup 8 = over 127 = or if
      drop #tib @ if -1 #tib +! 8 emit space 8 emit then
    else
      #tib @ 80 < if dup emit tib #tib @ + c! 1 #tib +! else drop then
    then
  repeat drop space ;

\ SNAP copies the data stack into SSNAP and the float stack into FSSNAP (bottom
\ first) before each line, for the app's stack views. SDEPTH is -1 while the
\ copies are in progress.
create ssnap 80 allot
variable sdepth
create fssnap 80 allot
variable fsdepth
: snap ( -- )
  -1 sdepth ! depth dup >r
  begin dup while 1- swap over cells ssnap + ! repeat drop
  r@ 0 begin 2dup > while dup cells ssnap + @ -rot 1+ repeat 2drop
  fdepth dup >r
  begin dup while 1- f>bits over cells fssnap + ! repeat drop
  r@ 0 begin 2dup > while dup cells fssnap + @ bits>f 1+ repeat 2drop
  r> fsdepth ! r> sdepth ! ;

: quit ( -- )
  0 state !
  begin snap accept-line interpret state @ 0= if ."  ok" then cr again ;

: cold ( -- )
  decimal 0 state ! 7 set-precision
  cr ." HF32 Forth on Arty Z7-20" cr
  1 led!
  quit ;
