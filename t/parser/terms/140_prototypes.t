#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 5;

use lib 't/lib';
use TestParser qw(:all);

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print defined 1, 2
EOP
--- !parsetree:Print
arguments:
  - !parsetree:Builtin
    arguments:
      - !parsetree:Number
        flags: NUM_INTEGER
        type: number
        value: 1
    function: defined
  - !parsetree:Number
    flags: NUM_INTEGER
    type: number
    value: 2
filehandle: ~
function: print
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print unlink 1, 2
EOP
--- !parsetree:Print
arguments:
  - !parsetree:Overridable
    arguments:
      - !parsetree:Number
        flags: NUM_INTEGER
        type: number
        value: 1
      - !parsetree:Number
        flags: NUM_INTEGER
        type: number
        value: 2
    function: unlink
filehandle: ~
function: print
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
open FILE, ">foo" or die "error";
EOP
--- !parsetree:BinOp
left: !parsetree:Overridable
  arguments:
    - !parsetree:Symbol
      name: FILE
      sigil: '*'
    - !parsetree:Constant
      type: string
      value: '>foo'
  function: open
op: or
right: !parsetree:Overridable
  arguments:
    - !parsetree:Constant
      type: string
      value: error
  function: die
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
print FILE $stuff;
EOP
--- !parsetree:Print
arguments:
  - !parsetree:Symbol
    name: stuff
    sigil: $
filehandle: !parsetree:Symbol
  name: FILE
  sigil: '*'
function: print
EOE

parse_and_diff_yaml( <<'EOP', <<'EOE' );
pipe $foo, FILE
EOP
--- !parsetree:Overridable
arguments:
  - !parsetree:Symbol
    name: foo
    sigil: $
  - !parsetree:Symbol
    name: FILE
    sigil: '*'
function: pipe
EOE
