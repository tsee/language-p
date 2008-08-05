#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 3;

use lib 't/lib';
use TestParser qw(:all);

parse_and_diff_yaml( <<'EOP', <<'EOE' );
BEGIN {
    1
}
EOP
--- !parsetree:Subroutine
lines:
  - !parsetree:Number
    flags: NUM_INTEGER
    type: number
    value: 1
name: BEGIN
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
sub END {
    1
}
EOP
--- !parsetree:Subroutine
lines:
  - !parsetree:Number
    flags: NUM_INTEGER
    type: number
    value: 1
name: END
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
END {
    1
}
EOP
--- !parsetree:Subroutine
lines:
  - !parsetree:Number
    flags: NUM_INTEGER
    type: number
    value: 1
name: END
EOE
