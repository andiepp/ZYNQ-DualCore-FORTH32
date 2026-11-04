\ lights.fs - a running light on LD0..LD3 (manual, section 2.9)
: step ( n -- n' ) 2* dup 16 = if drop 1 then ;
: lights ( n -- ) 1 swap 0 do dup led! step 200 ms loop drop 0 led! ;
: hello ." lights ready" cr ;
hello
