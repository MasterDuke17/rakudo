use lib <t/packages/Test-Helpers>;
use Test::Helpers::QAST;
use Test;
use QAST:from<NQP>;
use nqp;
plan 28;

# A call to a named setting routine compiles its callee lookup as a static
# one, which the VM may resolve a single time. So does a call to a routine
# bound once in the outermost scope of the compilation unit: a sub
# declaration, which cannot be rebound, or an import, which is installed
# once at load. A `my &f` variable keeps the plain lookup since it can be
# rebound at runtime, and so does a routine declared in a nested scope,
# whose enclosing frame may bind a fresh clone per entry.

sub qast-op-named (Mu $qast, Str:D $op, Str:D $name --> Bool:D) {
    if nqp::istype($qast, QAST::Op) && $qast.op eq $op && $qast.name eq $name {
        return True;
    }
    elsif qast-descendable $qast {
        for $qast.list {
            qast-op-named $_, $op, $name and return True;
        }
    }
    False
}

# These observe the emitted QAST.
qast-is 'my $x = 1; say $x', -> \v {
        qast-op-named(v, 'callstatic', '&say')
    and not qast-op-named(v, 'call', '&say')
}, 'a call to a setting routine compiles to a static callee lookup';

qast-is 'my $s = "hi"; chars $s', -> \v {
        qast-op-named(v, 'callstatic', '&chars')
    and not qast-op-named(v, 'call', '&chars')
}, 'a setting routine whose value is used compiles to a static callee lookup';

qast-is '{ my sub f($x) { return $x + 1 }; f(1) }', :full, -> \v {
        qast-op-named(v, 'call', '&f')
    and not qast-op-named(v, 'callstatic', '&f')
}, 'a call to a nested user routine keeps the plain callee lookup';

qast-is 'sub foo($x) { return $x }; foo(1)', -> \v {
        qast-op-named(v, 'callstatic', '&foo')
    and not qast-op-named(v, 'call', '&foo')
}, 'a call to a sub declared in the outermost scope compiles to a static callee lookup';

qast-is 'multi sub mf(Int $x) { return 1 }; multi sub mf(Str $x) { return 2 }; mf(1)', -> \v {
        qast-op-named(v, 'callstatic', '&mf')
    and not qast-op-named(v, 'call', '&mf')
}, 'a call to a multi declared in the outermost scope compiles to a static callee lookup';

# The recursive call inside the sub is not asserted on: the sub's own name
# is visible in its own scope, so the mark declines it there.
qast-is 'sub fact($n) { return 1 if $n < 2; fact($n - 1) * $n }; fact(5)', -> \v {
    qast-op-named(v, 'callstatic', '&fact')
}, 'the outer call to a recursive sub compiles to a static callee lookup';

qast-is 'use Test; plan 1', -> \v {
        qast-op-named(v, 'callstatic', '&plan')
    and not qast-op-named(v, 'call', '&plan')
}, 'a call to an imported routine compiles to a static callee lookup';

qast-is 'my &foo = sub { 1 }; foo()', -> \v {
        qast-op-named(v, 'call', '&foo')
    and not qast-op-named(v, 'callstatic', '&foo')
}, 'a call through a routine variable keeps the plain callee lookup';

# A single comparison is a static lookup under both frontends, though they
# differ in shape: the legacy optimizer first rewrites the one-link chain
# to a plain call.
qast-is 'my $a = 1; my $b = 2; $a == $b', -> \v {
    (qast-op-named(v, 'chainstatic', '&infix:<==>')
        or qast-op-named(v, 'callstatic', '&infix:<==>'))
    and not qast-op-named(v, 'chain', '&infix:<==>')
    and not qast-op-named(v, 'call', '&infix:<==>')
}, 'a comparison against a setting operator compiles to a static callee lookup';

qast-is 'my $a = 1; my $b = 2; my $c = 3; $a == $b == $c', -> \v {
        qast-op-named(v, 'chainstatic', '&infix:<==>')
    and not qast-op-named(v, 'chain', '&infix:<==>')
}, 'a chained comparison against a setting operator compiles to static chain links';

qast-is '{ my multi sub infix:<==>(\a, \b) { return 3 }; my $x = "a"; my $y = "b"; $x == $y }', :full, -> \v {
    not qast-op-named(v, 'chainstatic', '&infix:<==>')
}, 'a comparison against a nested user operator keeps the plain lookup';

# These observe that statically looked up callees still behave.
{
    my $s = "HI";
    is chars($s), 2, 'a setting routine called by name returns its value';
}
{
    sub f { return 42; 99 }
    is f(), 42, 'return unwinds through a static callee lookup';
}
{
    is (gather { take 1; take 2 }).join(','), '1,2',
        'take reaches the enclosing gather through a static callee lookup';
}
{
    sub g { fail "nope" }
    my $f = g();
    ok $f ~~ Failure, 'fail produces a Failure through a static callee lookup';
    $f.so;
}
{
    my @a = 1, 2, 3;
    is elems(@a), 3, 'a multi setting routine called by name returns its value';
}
{
    my $out = do { use soft; my $s = "hi"; uc $s };
    is $out, 'HI', 'a setting routine still runs under the soft pragma';
}
# These subs live in the test file's outermost scope so the calls below
# exercise the static lookup path at runtime. Their names are distinct from
# the ones in the compiled snippets above, which share this file's context.
my $base = 10;
sub rt-fact($n) { return 1 if $n < 2; rt-fact($n - 1) * $n }
multi sub rt-mf(Int $x) { return 1 }
multi sub rt-mf(Str $x) { return 2 }
sub rt-add($x) { $base + $x }

is rt-fact(5), 120, 'a recursive outermost-scope sub computes through static lookups';
is rt-mf(1), 1, 'a multi called with an Int picks the Int candidate';
is rt-mf("x"), 2, 'a multi called with a Str picks the Str candidate';
is rt-add(5), 15, 'an outermost-scope sub closing over a mainline lexical reads it';

# Chained comparisons still follow the chaining protocol through static
# operator lookups.
my $lo = 1;
my $mid = 2;
my $hi = 3;
ok $lo < $mid < $hi, 'a true chained comparison holds through static links';
nok $lo < $hi < $mid, 'a false chained comparison fails through static links';
my $rt-mid-calls = 0;
sub rt-mid { $rt-mid-calls++; 2 }
ok 1 < rt-mid() < 3, 'a chained comparison with a call in the middle holds';
is $rt-mid-calls, 1, 'the middle operand of a chained comparison runs once';
ok ?(any(1, 2) < 3), 'a Junction autothreads through a static comparison';

# The fatalize pass recognizes a static callee lookup both as a call whose
# Failure it promotes and as a boolifying consumer that disarms its argument.
sub rt-will-fail() { fail 'nope' }
{
    sub rt-nested-fail() { fail 'nope' }
    lives-ok { use fatal; my $x = defined rt-nested-fail(); 1 },
        'use fatal respects defined through a static callee lookup';
}
dies-ok { use fatal; my $x = rt-will-fail(); 1 },
    'use fatal promotes a Failure from a static callee lookup';

# vim: expandtab shiftwidth=4
